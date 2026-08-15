# Build-out phases

The phases are a build order, not a menu. Three phases are built and running;
what changes from one to the next is which layer is being added, not whether it
will exist. Everything beyond them is a [next step](#next-steps) rather than a
phase, because it adds no layer to build.

## The end state

The destination is an agent platform: agents that reach private data through
declared tools, are scored automatically instead of reviewed by hand, and are
routed on those scores. Automated evaluation is the load-bearing part — an agent
takes several steps over a large output space, so it cannot be checked by eye,
and a routing decision has nothing to act on until something scores it.

When the build-out is complete, one `stack.yaml` describes a stack in which:

- every request enters through one OpenAI-compatible gateway, whichever model
  serves it
- models are served on infrastructure the operator chooses, with commercial APIs
  as an optional addition rather than a dependency
- agents reach private data through declared, scoped MCP servers instead of
  through code embedded in an application
- routing, guardrails, and evaluation are configured at the gateway, so they
  apply to every client at once
- output quality is scored automatically by a judge model, and those scores
  feed back into routing

The last bullet is the destination, not an extra feature. Every layer before it
exists to make it possible: the gateway is the one place that both measures a
request and decides where it goes, tracing turns quality into data instead of
anecdote, and self-hosted serving makes a judge affordable to run on every
sampled request.

One acceptance test bounds the arc:

| Test | What it proves | Made possible by |
|---|---|---|
| An aggregate judge score changes a routing decision, and both the score and the change are observable | the loop is closed | [Judge-scored routing](#judge-scored-routing) |

This is partially in place: Phase 1 computes five automated scores per trace
(routing accuracy, language consistency, latency, and two LLM-as-judge scores),
and a user-feedback sidecar attaches ratings from LibreChat to those same traces.
The scores exist; routing does not yet act on them.

## Order and current state

The order is frontier-first: establish one gateway and one trace pipeline
against commercial APIs, then add tools, then self-hosted serving. Phase 1
proves the gateway, provider abstraction, tracing, and cost attribution without
introducing GPU provisioning, so every later layer plugs into a request and
observability path that already works. Phase profiles are cumulative.

```bash
./scripts/stack.sh phases
```

| Phase | Outcome | Target | Status |
|:--:|---|---|---|
| 1 | Frontier models through LiteLLM, traced in Langfuse | Docker or EC2 | **Running** (EC2 + Docker) |
| 2 | MCP tool layer — ClickHouse Cloud | EC2 | **Running** (EC2) |
| 3 | GPU serving on RunPod | EC2 + RunPod | **Running** (EC2 + RunPod) |

Phase 1 runs on either `--target docker` (local) or `--target aws-ec2`. Phase 2
and above require EC2, and RunPod is an external service regardless of where the
gateway lives.

The Kubernetes deployment artifact is not implemented. A profile can describe a
layer before that layer is runnable; `stack.sh` warns and skips disabled layers.

## Phase 1 — Frontier models

**Adds:** LiteLLM, Langfuse, LibreChat, Anthropic (optionally OpenAI),
Cloudflare Workers AI for images, and the feedback sidecar. No GPU.

**Target:** `docker` (local) or `aws-ec2`.

```bash
./scripts/stack.sh up --profile phase-1
```

Acceptance criteria:

- at least one provider responds through LiteLLM
- the same model catalog appears in LiteLLM and LibreChat
- success and failure telemetry reaches Langfuse
- per-model token and cost data is visible
- every completion trace carries five automated scores: `routing_accuracy`,
  `language_consistency`, `latency_score`, `helpfulness`, and
  `judge_language_match`
- sessions grouped by user ID are visible in Langfuse
- GENERATION observations carry model name, token counts, and cost
- user ratings submitted through the feedback sidecar correlate to Langfuse trace IDs
- the judge prompt (`judge-v1`) is versioned in Langfuse's prompt catalog

The profile starts nine local containers: LiteLLM, LibreChat, the feedback sidecar, and six Langfuse services (web, worker, Postgres, Redis, MinIO, MongoDB). Langfuse connects to **ClickHouse Cloud** for trace analytics (`llmops` database) — there is no local ClickHouse container.

!!! warning "Phase 1 sends every request to a commercial provider"
    The gateway and tracing run inside the deployment; the model inference does
    not. That is true of Phase 3 as well, where the GPU worker runs on RunPod.
    Nothing in this repository serves a model inside the deployment's own
    network boundary.

## Phase 2 — MCP tool layer

**Adds:** `mcp-clickhouse` service (port 9100, internal network only) with SSE
transport, wired into the LiteLLM gateway via `mcp_servers`.

**Target:** `aws-ec2` only. Phase 2 requires the EC2 target; see
[Getting started — Moving to Phase 2](getting-started.md#moving-to-phase-2).

Deploy with:

```bash
./scripts/stack.sh render --profile phase-2 --target aws-ec2
./scripts/stack.sh up --profile phase-2 --target aws-ec2
```

The `mcp-clickhouse` container is built from `docker/mcp/Dockerfile`
(`python:3.12-slim` + `mcp-clickhouse` + `mcp-proxy` packages) and connects to
ClickHouse Cloud via `CLICKHOUSE_HOST`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`,
and `CLICKHOUSE_SECURE=true`. Tool access is declared at the **gateway** layer,
not at the client: every app reaching LiteLLM inherits the same tools
automatically.

The gateway injects the tools and runs the agentic loop itself (up to five
hops), so a client that knows nothing about MCP still gets a plain text answer
built from tool results. Each tool execution is traced as a `tool-result/<name>`
span and each follow-up model call as a `<model>/tool-hop-N` generation, so the
warehouse access and the loop's token spend both sit in the same trace as the
request that caused them.

!!! note "Tools are injected for Korean-language requests only"
    Language routing sends Korean to `claude-sonnet` and English/CJK to
    `qwen-7b`. `qwen-7b` is not reliable enough at function calling to be handed
    tool schemas, so `UnifiedRouter` injects MCP tools only when the request is
    Hangul-primary. Widening this means either a tool-capable self-hosted model
    or routing tool-shaped requests to `claude-sonnet` regardless of language.

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

## Phase 3 — GPU serving on RunPod

**Adds:** vLLM and `qwen-7b` on a RunPod Serverless endpoint alongside the
commercial APIs. Language routing directs Korean to `claude-sonnet` and
English/CJK to `qwen-7b`.

**Target:** `aws-ec2` + RunPod. The gateway and observability stack run on EC2;
the GPU inference endpoint is provisioned separately on RunPod.

The serving layer is externally managed — not a Compose container. LiteLLM
needs only an authenticated OpenAI-compatible `VLLM_API_BASE`. The endpoint is
provisioned in the RunPod console; nothing in this repository changes.

Acceptance criteria:

- `claude-sonnet` and `qwen-7b` use the same client protocol and both appear in
  one Langfuse project
- traces for `qwen-7b` carry the `provider:runpod` tag
- `qwen-7b` falls back to `claude-sonnet` when the RunPod endpoint is stopped
- GPU runtime cost is configurable via `RUNPOD_COST_PER_TOKEN`

`qwen-7b` falls back to `claude-sonnet` in connected profiles (600 s timeout
accounts for RunPod Serverless cold start; `min_workers=1` in the RunPod console
avoids it).

## Next steps

These are not phases. Each one is a way of operating the gateway, tools,
serving, and trace data the three phases already deliver — no new layer, no new
container, and therefore no profile to bring up. Giving them phase numbers would
imply a deployable artifact that does not exist.

`./scripts/stack.sh phases` prints them beneath the three phases, from the
`next_steps` block in `stack.yaml`.

### Context-based routing

Start with deterministic rules: explicit tenant policy, requested capability,
context-window fit, health, and budget. LiteLLM can route an over-length
request through context-window fallbacks.

```yaml
router_settings:
  context_window_fallbacks:
    - qwen-7b: [claude-sonnet]
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

### LibreChat Agents over the MCP tool layer

Configure an agent with the Phase 2 MCP server and verify that one trace
contains planning, tool use, and the final response. Use only the dedicated
read-only database credential.

### Langfuse evaluations

Create a dataset from real traces, apply an explicit scoring rubric, and compare
cost and quality across the same inputs. Record the judge model; using a model
to judge itself can bias the result.

### Guardrails at the gateway

Gateway guardrails cover every client. PII and prompt-injection checks must run
before a request leaves the deployment; output moderation runs after inference.
A hosted guardrail also receives the prompt, so it cannot be used to support an
in-boundary claim.

Acceptance criteria:

- synthetic sensitive data is redacted or blocked before provider egress
- the trace shows which guardrail ran and its outcome
- false positives, false negatives, and latency are measured

### Judge-scored routing

Context-based routing decides where a request goes. Langfuse evaluations decide
how good the answer was. Joining them is the point of the build-out: scores stop
being a dashboard and become an input to routing.

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
  boundaries.** This is the same rule that applies to the intent classifier.
  Quality may choose among already-permitted routes; it may not widen the
  permitted set.
- **The judge is a model, so it is traced and costed like any other call.** Its
  spend belongs in the same Langfuse view as the traffic it judges, or the
  loop's own cost stays invisible while it changes routing.
- **A model judging its own output biases the result.** If the judge and a
  candidate route are the same model, that comparison is not neutral.
- **Sample until judge/human agreement is measured.** An unvalidated judge
  driving automated routing is an unmeasured system changing its own behaviour.
- **A hosted judge sees the prompt.** It receives both the prompt and the
  completion, for exactly the reason a hosted guardrail does. Any claim about a
  boundary requires the judge to be inside it.

Acceptance criteria:

- judge scores are attached to traces and queryable per model and per route
- a documented rule maps aggregate scores to a routing change, and applying that
  rule is observable in the trace data
- judge spend appears as its own line beside serving cost
- judge/human agreement is measured on a sample before any automated routing
  change is enabled

## Profiles

| Profile | Layers | Models |
|---|---|---|
| `phase-1` | gateway, observability, UI | `claude-sonnet` |
| `phase-2` | Phase 1 + tools | `claude-sonnet` |
| `phase-3` | Phase 2 + GPU serving (RunPod) | `claude-sonnet` + `qwen-7b` |
| `headless` | gateway and observability | enabled models |
| `full` | every layer whose `enabled` is true | enabled models |

`stack.yaml` remains authoritative for exact membership and current status.
