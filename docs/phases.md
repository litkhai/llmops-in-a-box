# Build-out phases

The stack is built frontier-first: establish one gateway and one trace pipeline
against commercial APIs, then add tools, self-hosted serving, storage, and
operating recipes. Phase profiles are cumulative.

```bash
./scripts/stack.sh phases
```

## Current status

| Phase | Outcome | Status |
|:--:|---|---|
| 1 | Frontier models through LiteLLM, traced in Langfuse | **In progress; Docker runnable** |
| 2 | MCP tool layer | Planned |
| 3 | Self-hosted vLLM serving | Planned |
| 4 | Artifact storage and KV-cache reuse | Planned |
| 5 | Routing, agents, evaluations, and guardrails | Planned |

The AWS and Kubernetes deployment artifacts are also not implemented. A
profile can describe planned layers before those layers are runnable;
`stack.sh` warns and skips disabled layers.

## Why this order

Phase 1 proves the gateway, provider abstraction, tracing, and cost attribution
without introducing GPU provisioning. Later layers can then be tested against
a known-good request and observability path.

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

**Adds:** MCP tools, starting with ClickHouse Cloud.

The first implementation should expose a dedicated read-only ClickHouse
credential and record tool calls beside the model calls that caused them.

Acceptance criteria:

- an agent answers a question that requires private warehouse data
- the trace contains the tool arguments, result, latency, and failure state
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
gateway, tools, serving, and trace data built earlier.

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
