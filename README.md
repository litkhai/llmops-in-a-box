# LLMOps in a Box

A composable LLMOps reference stack built around a single gateway:

- **LiteLLM** for model routing and cost tracking
- **Langfuse** for traces, sessions, datasets, scores, and evaluations
- **LibreChat** for the user interface
- **Anthropic** (optionally OpenAI) for chat, **Cloudflare Workers AI** for image generation, and **MinIO** for image storage
- **ClickHouse Cloud** as the first MCP tool server, wired into the gateway
- **vLLM on RunPod Serverless** for GPU serving of `qwen-7b`

All three phases run today on the `aws-ec2` target.

The phases are a build order rather than a menu. The destination is an agent
platform: models served on infrastructure the operator chooses, private data
reached through scoped MCP servers, and — the part the rest exists for —
outputs scored automatically by a judge model, with those scores feeding back
into routing. Automated evaluation is what makes an agent operable rather than
demoable; it takes too many steps to check by hand, and routing has nothing to
act on until something scores it. Phase 1 builds the gateway and trace pipeline
everything after it plugs into, because closing that loop needs one point that
both measures a request and decides where it goes.

Scoring is in place: every completion trace carries five automated scores plus
user ratings. Routing does not act on them yet — that, and the other operating
recipes, are [next steps](#next-steps) rather than numbered phases, because they
add no layer to build.

Both runnable targets are single-node Docker Compose deployments — one on a
laptop (`--target docker`, Phase 1), one on EC2 (`--target aws-ec2`, all three
phases). `stack.yaml` is the source of truth for layers, models, profiles,
credential names, and deployment targets.

[Documentation](https://litkhai.github.io/llmops-in-a-box/) ·
[Getting started](https://litkhai.github.io/llmops-in-a-box/getting-started/)

## Current status

| Scope | Target | Status |
|---|---|---|
| Phase 1 — gateway, UI, tracing | Docker or EC2 | Running (EC2 + Docker) |
| Anthropic / OpenAI requests through LiteLLM | — | Requires at least one provider key |
| Image generation (Cloudflare Workers AI FLUX.1-schnell) | — | Running |
| LiteLLM → Langfuse tracing, five automated scores per trace | — | Running |
| User feedback sidecar (ratings → Langfuse scores) | — | Running |
| Phase 2 — MCP tool layer (ClickHouse Cloud) | EC2 | Running |
| Phase 3 — GPU serving on RunPod (`qwen-7b`) | EC2 + RunPod | Running |
| [Next steps](#next-steps) — routing, agents, evals, guardrails, judge-scored routing | EC2 | Not built |

If Langfuse traces are missing, a `LANGFUSE_MIGRATION_V4_WRITE_MODE` incompatibility in Langfuse v4 RC builds may be the cause — see [Deployment troubleshooting](https://litkhai.github.io/llmops-in-a-box/deployment/#troubleshooting) for details.

No phase of this stack is an air-gapped deployment. Phase 1 sends every model
request to a commercial provider, and the Phase 3 GPU worker runs on RunPod —
outside the deployment's own network. Both demonstrate the gateway and
observability architecture; neither makes the network boundary a control. Doing
that would mean serving a model inside the boundary, which nothing in this
repository provisions today.

## Quick start

Requirements: Docker 24+ with Compose v2 and
[mikefarah/yq](https://github.com/mikefarah/yq) v4.

```bash
brew install yq

./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1
# in the menu: d → provider key(s) → g → w → q

./scripts/stack.sh doctor
./scripts/stack.sh up
./scripts/stack.sh status
```

Open:

| Service | URL |
|---|---|
| LibreChat | <http://localhost:3080> |
| LiteLLM | <http://localhost:4000> |
| Langfuse | <http://localhost:3000> |

Use the [getting-started guide](https://litkhai.github.io/llmops-in-a-box/getting-started/)
for machine and credential preparation, then follow the
[workshop](https://litkhai.github.io/llmops-in-a-box/workshop/) for the first
traced request.

## Architecture

The shape the stack is built toward, with the phase that delivers each path:

```text
LibreChat / applications
        │
        └─ chat (model: auto)
               │
               ▼
LiteLLM Gateway ──────────── traces ─────────▶ Langfuse
(UnifiedRouter callback)                           │
        │                                       ClickHouse Cloud · Postgres · Redis · MinIO
        │                                   feedback sidecar (ratings → Langfuse scores)
        ├─ auto · Korean text ──────▶ claude-sonnet              phase 1
        ├─ auto · English/CJK text ─▶ qwen-7b (vLLM on RunPod)   phase 3
        ├─ auto · image keywords ───▶ Cloudflare FLUX.1-schnell  phase 1
        │                  stores ──▶ MinIO → media.<domain>
        └─ Korean text ─────────────▶ MCP tools (ClickHouse Cloud) phase 2
                                      injected at the gateway
```

One model alias (`auto`) in the chat UI routes to the right provider: Korean →
`claude-sonnet`, English/CJK → `qwen-7b` on RunPod Serverless, image-intent
messages → Cloudflare Workers AI FLUX.1-schnell. All of it runs through
`UnifiedRouter`, which logs completion calls to Langfuse via the SDK directly —
routing decisions and MCP tool-result spans included.

ClickHouse Cloud is exposed as an MCP server wired into the LiteLLM gateway, so
every tool call is traced alongside the model call that triggered it and no
client-side wiring is required. Tools are injected for Korean-language requests
only, because those route to `claude-sonnet`; `qwen-7b` is not reliable enough at
function calling to be given tool schemas.

Applications use one OpenAI-compatible endpoint. LiteLLM resolves the model
alias; `UnifiedRouter` logs completion calls directly to Langfuse via the SDK,
so only meaningful model calls appear in traces rather than management API noise.
The model catalog is
rendered from `stack.yaml` into both LiteLLM and LibreChat configuration.
Adding a later layer changes gateway configuration, not client code.

## Build-out

| Phase | Outcome | Target | Status |
|:--:|---|---|---|
| 1 | Gateway, UI, and tracing over frontier APIs | Docker or EC2 | Running |
| 2 | MCP tool layer, starting with ClickHouse Cloud | EC2 | Running |
| 3 | GPU serving on RunPod (`qwen-7b`) | EC2 + RunPod | Running |

Phase 1 runs locally with `--target docker` or on `--target aws-ec2`. Phase 2
and above require EC2: ClickHouse Cloud MCP needs reliable outbound access, and
RunPod is an external service regardless of where the gateway lives.

See [Build-out phases](https://litkhai.github.io/llmops-in-a-box/phases/) for
the end state, the acceptance criteria of each phase, and why the order is what
it is.

## Next steps

Not phases. Each one is a way of operating the layers Phases 1–3 already
deliver, so none of them adds a container or a profile — which is also why they
carry no phase number.

| Next step | What it adds |
|---|---|
| Context-based routing | Deterministic rules — tenant, capability, context-window fit, health, budget — then an intent classifier in front of them |
| LibreChat Agents over MCP | An agent over the Phase 2 tools, with planning, tool use, and response in one trace |
| Langfuse evaluations | Datasets from real traces, an explicit rubric, cost and quality compared on the same inputs |
| Guardrails at the gateway | PII and prompt-injection checks before egress, output moderation after inference, both traced |
| Judge-scored routing | Aggregate judge scores feeding back into routing — the loop the phases exist to make possible |

`./scripts/stack.sh phases` prints these beneath the three phases. Details and
acceptance criteria: [Build-out phases — Next steps](https://litkhai.github.io/llmops-in-a-box/phases/#next-steps).

## Control plane

```bash
./scripts/stack.sh config
./scripts/stack.sh models
./scripts/stack.sh phases
./scripts/stack.sh render
./scripts/stack.sh up
./scripts/stack.sh status
./scripts/stack.sh logs
./scripts/stack.sh down
```

Credential commands:

```bash
./scripts/stack.sh secrets setup --phase 1
./scripts/stack.sh secrets status --all
./scripts/stack.sh secrets validate --all
./scripts/stack.sh secrets write
./scripts/stack.sh secrets audit
```

`secrets/credentials.yaml` is the private credential source; `.env` is
generated from it. Neither file should be committed or printed. See
[Credentials](https://litkhai.github.io/llmops-in-a-box/credentials/).

## Repository layout

```text
stack.yaml                  declarative source of truth
scripts/stack.sh            control plane
docker/                     runnable Phase 1 + 2 Compose target
secrets/                    credential template and local inventory
docs/                       MkDocs documentation
terraform/                  AWS EC2 provisioning
AGENTS.md                   repository guidance for coding agents
```

Generated files `docker/litellm_config.yaml` and `docker/librechat.yaml` must
not be edited directly. Change `stack.yaml`, then run:

```bash
./scripts/stack.sh render
```

## Documentation map

| Need | Page |
|---|---|
| Prepare a machine and credentials | [Getting started](https://litkhai.github.io/llmops-in-a-box/getting-started/) |
| Run the Phase 1 exercise | [Workshop](https://litkhai.github.io/llmops-in-a-box/workshop/) |
| Understand the design choices | [Background](https://litkhai.github.io/llmops-in-a-box/background/) |
| See the end state and the build order | [Build-out phases](https://litkhai.github.io/llmops-in-a-box/phases/) |
| Change layers or models | [Configuration](https://litkhai.github.io/llmops-in-a-box/configuration/) |
| Operate a deployment target | [Deployment](https://litkhai.github.io/llmops-in-a-box/deployment/) |
| Fix a known issue | [Troubleshooting](https://litkhai.github.io/llmops-in-a-box/troubleshooting/) |
| Present the stack | [Demo flow](https://litkhai.github.io/llmops-in-a-box/demo-flow/) |

## License

MIT
