# Build-out phases

The phases are a build order, not a menu. Every layer on this page is in scope
and intended to ship; what changes from one phase to the next is which layer is
being built, not whether it will exist. The Status column reports implementation
state, not scope.

## The end state

The destination is an agent platform: agents that reach private data through
declared tools, are scored automatically instead of reviewed by hand, and are
routed on those scores. Automated evaluation is the load-bearing part — an agent
takes several steps over a large output space, so it cannot be checked by eye,
and a routing decision has nothing to act on until something scores it.

When the build-out is complete, one `stack.yaml` describes a stack in which:

- every request enters through one OpenAI-compatible gateway, whichever model
  serves it
- models are served inside the network boundary, with commercial APIs as an
  optional addition rather than a dependency
- agents reach private data through declared, scoped MCP servers instead of
  through code embedded in an application
- datasets, eval artifacts, and model weights live in an object store the
  operator owns
- a long shared prompt prefix is prefilled once and reused instead of
  recomputed on every request
- routing, guardrails, and evaluation are configured at the gateway, so they
  apply to every client at once
- output quality is scored automatically by a judge model, and those scores
  feed back into routing

The last bullet is the destination, not an extra feature. Every layer before it
exists to make it possible: the gateway is the one place that both measures a
request and decides where it goes, tracing turns quality into data instead of
anecdote, self-hosted serving makes a judge affordable to run on every sampled
request and keeps prompts inside the boundary, and the artifact store holds the
datasets the judge is calibrated against.

Two acceptance tests bound the arc:

| Test | What it proves | Made possible by |
|---|---|---|
| `--profile airgapped` resolves to a working stack with no commercial model and no commercial fallback anywhere in the generated config | the boundary is real, not configured | Phase 3 |
| An aggregate judge score changes a routing decision, and both the score and the change are observable | the loop is closed | Phase 5 |

Neither passes today. The first cannot, because there is no self-hosted model to
fall back to; the second cannot, because nothing scores anything yet.

## Order and current state

The order is frontier-first: establish one gateway and one trace pipeline
against commercial APIs, then add tools, self-hosted serving, storage, and
operating recipes. Phase 1 proves the gateway, provider abstraction, tracing,
and cost attribution without introducing GPU provisioning, so every later layer
plugs into a request and observability path that already works. Phase profiles
are cumulative.

```bash
./scripts/stack.sh phases
```

| Phase | Outcome | Status |
|:--:|---|---|
| 1 | Frontier models through LiteLLM, traced in Langfuse | **Runnable — Docker and AWS EC2** |
| 2 | MCP tool layer | **Runnable — ClickHouse Cloud via MCP** |
| 3 | Self-hosted vLLM serving | Not built yet |
| 4 | Artifact storage and KV-cache reuse | Not built yet |
| 5 | Routing, agents, guardrails, and judge-scored routing | Not built yet |

The AWS and Kubernetes deployment artifacts are not implemented either. A
profile can describe a layer before that layer is runnable; `stack.sh` warns and
skips disabled layers.

## Phase 1 — Frontier models

**Adds:** LiteLLM, Langfuse, LibreChat, OpenAI, and Anthropic. No GPU.

```bash
./scripts/stack.sh up --profile phase-1
```

Acceptance criteria:

- at least one provider responds through LiteLLM
- the same model catalog appears in LiteLLM and LibreChat
- success and failure telemetry reaches Langfuse
- per-model token and cost data is visible

The profile starts nine containers because Langfuse and LibreChat require
ClickHouse, Postgres, Redis, MinIO, MongoDB, and a worker in addition to their
visible services.

!!! warning "Phase 1 is not sovereign"
    Every model request goes to OpenAI or Anthropic. The gateway and tracing
    run locally, but the model inference does not stay inside the network
    boundary.

## Phase 2 — MCP tool layer

**Adds:** `mcp-clickhouse` service (port 9100, internal network only) with SSE
transport, wired into the LiteLLM gateway via `mcp_servers`.

Deploy with:

```bash
./scripts/stack.sh render --profile phase-2
./scripts/stack.sh up --profile phase-2
```

The `mcp-clickhouse` container is built from `docker/mcp/Dockerfile`
(`python:3.12-slim` + `mcp-clickhouse` package) and connects to ClickHouse
Cloud via `CLICKHOUSE_HOST`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, and
`CLICKHOUSE_SECURE=true`. Tool access is declared at the **gateway** layer, not
at the client: every app reaching LiteLLM inherits the same tools
automatically.

All tool calls are traced through LiteLLM → Langfuse alongside the model calls
that triggered them.

Acceptance criteria:

- `mcp-clickhouse` starts and the gateway reports the `clickhouse` server in
  its MCP server list
- an agent answers a question that requires ClickHouse data without any
  client-side tool wiring
- the Langfuse trace contains the tool arguments, result, latency, and failure
  state beside the parent model call
- a write attempt fails at the database permission boundary

Prompt instructions are not access control. The MCP credential's database
grants determine what the agent can do.

## Phase 3 — Self-hosted serving

**Adds:** vLLM and `qwen-7b`, initially on a RunPod GPU endpoint.

The serving layer is externally managed rather than a Compose container.
LiteLLM needs only an authenticated OpenAI-compatible `VLLM_API_BASE`.

Acceptance criteria:

- `gpt-4o`, `claude-sonnet`, and `qwen-7b` use the same client protocol
- all three appear in one Langfuse project
- the air-gapped profile contains no commercial model or fallback
- GPU runtime cost is reported separately from Langfuse's per-token data

`qwen-7b` can fall back to `gpt-4o` in connected profiles. The renderer must
prune that fallback in `airgapped`; a stopped local model should fail rather
than silently egress.

## Phase 4 — Storage and large context

**Adds:** a separate MinIO AIStor artifact store and LMCache-based KV-cache
reuse.

The artifact store is separate from the MinIO instance internal to Langfuse:

| Langfuse MinIO | Phase 4 store |
|---|---|
| Owned by Langfuse | Owned by the stack operator |
| Trace and media internals | Datasets, eval artifacts, model weights |
| Lifecycle follows Langfuse | Independent retention and backup policy |

### Phase 4a — KV-cache reuse

vLLM prefix caching and LMCache avoid recomputing a shared prompt prefix. The
cache should stay near the GPU:

- RunPod serving → pod-local RAM or NVMe
- local NVIDIA host → a local backend, potentially the Phase 4 object store

A remote pod should not fetch KV blocks from a laptop through a tunnel; latency
and prompt-derived data exposure defeat the purpose.

### Phase 4b — KV-cache offload at fleet scale

MinIO MemKV is tracked as a partnership/research path, not an installable phase
artifact. It is distinct from AIStor and from semantic response caching.
Availability, hardware requirements, and licensing must be confirmed before it
can become a build target.

## Phase 5 — Operating recipes

Phase 5 adds no infrastructure layer. It demonstrates how to operate the
gateway, tools, serving, and trace data built earlier — and in 5.5 it joins
routing to scoring, which is the capability the earlier phases were building
toward.

### 5.1 Context-based routing in LiteLLM

Start with deterministic rules: explicit tenant policy, requested capability,
context-window fit, health, and budget. LiteLLM can route an over-length
request through context-window fallbacks.

```yaml
router_settings:
  context_window_fallbacks:
    - qwen-7b: [gpt-4o]
```

When intent becomes important, add a classifier before normal routing:

```text
request
  → strict rules and safety constraints
  → intent classifier (small model or deterministic classifier)
  → constrained route candidates
  → LiteLLM health / retry / fallback routing
  → trace decision and confidence in Langfuse
```

An LLM-first classifier is possible, but should not control security,
residency, or hard budget boundaries. Give it a small label set, require
structured output, set a confidence threshold, and fall back to deterministic
routing when classification fails. Cache classifications for repeated prompt
shapes and trace both classifier cost and final route.

Acceptance criteria:

- short and over-length requests select models that can serve them
- route decisions and classifier confidence are observable
- low-confidence or failed classification takes a safe default
- `airgapped` never introduces a commercial candidate

### 5.2 LibreChat Agents over the MCP tool layer

Configure an agent with the Phase 2 MCP server and verify that one trace
contains planning, tool use, and the final response. Use only the dedicated
read-only database credential.

### 5.3 Langfuse evaluations

Create a dataset from real traces, apply an explicit scoring rubric, and compare
cost and quality across the same inputs. Record the judge model; using a model
to judge itself can bias the result.

### 5.4 Guardrails at the gateway

Gateway guardrails cover every client. PII and prompt-injection checks must run
before a request leaves the boundary; output moderation runs after inference.
A hosted guardrail also receives the prompt, so it cannot be used to support
an air-gapped claim.

Acceptance criteria:

- synthetic sensitive data is redacted or blocked before provider egress
- the trace shows which guardrail ran and its outcome
- false positives, false negatives, and latency are measured

### 5.5 Closing the loop — judge-scored routing

5.1 decides where a request goes. 5.3 decides how good the answer was. Joining
them is the point of the build-out: scores stop being a dashboard and become an
input to routing.

There are two loops here, and conflating them is the mistake to avoid — they
have different costs and different failure modes.

| | Offline — policy adaptation | Online — response-time re-route |
|---|---|---|
| Trigger | aggregate scores over a window | a low score on this request |
| Effect | the routing table changes | retry on a stronger model before answering |
| Added latency | none | judge call plus a second inference |
| Judge spend | on a sample | on every scored request |
| Failure mode | drift on noisy scores | user-visible latency; oscillation between routes |

Start with the offline loop. It is the one that pays for itself: a cheap model
carries the traffic, aggregate judge scores per route show where it is not good
enough, and the routing table changes deliberately. The online loop is worth its
latency only where a wrong answer costs more than a slow one.

Constraints that do not relax:

- **A judge score must not control residency, security, or hard budget
  boundaries.** This is the same rule 5.1 applies to the intent classifier.
  Quality may choose among already-permitted routes; it may not widen the
  permitted set.
- **The judge is a model, so it is traced and costed like any other call.** Its
  spend belongs in the same Langfuse view as the traffic it judges, or the
  loop's own cost stays invisible while it changes routing.
- **A model judging its own output biases the result** (5.3). If the judge and a
  candidate route are the same model, that comparison is not neutral.
- **Sample until judge/human agreement is measured.** An unvalidated judge
  driving automated routing is an unmeasured system changing its own behaviour.
- **`airgapped` requires a self-hosted judge.** A hosted judge API receives the
  prompt and the completion, so it defeats the boundary for exactly the reason
  a hosted guardrail does in 5.4.

Acceptance criteria:

- judge scores are attached to traces and queryable per model and per route
- a documented rule maps aggregate scores to a routing change, and applying that
  rule is observable in the trace data
- judge spend appears as its own line beside serving cost
- judge/human agreement is measured on a sample before any automated routing
  change is enabled
- `airgapped` resolves a self-hosted judge, or scoring is disabled in that
  profile rather than silently egressing

## Profiles

| Profile | Layers | Models |
|---|---|---|
| `phase-1` | gateway, observability, UI | `gpt-4o`, `claude-sonnet` |
| `phase-2` | Phase 1 + tools | frontier models |
| `phase-3` | Phase 2 + serving | frontier models + `qwen-7b` |
| `phase-4` | Phase 3 + storage and KV cache | all |
| `phase-5` | Same infrastructure as Phase 4 | all |
| `headless` | gateway and observability | enabled models |
| `airgapped` | gateway, observability, UI, serving | `qwen-7b` only |

`stack.yaml` remains authoritative for exact membership and current status.
