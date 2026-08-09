# LLMOps in a Box

A composable LLMOps reference stack built around a single gateway:

- **LiteLLM** for model routing and cost tracking
- **Langfuse** for traces, sessions, datasets, and evaluations
- **LibreChat** for the user interface
- **OpenAI and Anthropic** for chat, **Cloudflare Workers AI** for image generation, and **MinIO** for image storage — running today
- **ClickHouse Cloud** as the first MCP tool server, wired into the gateway — running today
- **llama.cpp, MinIO AIStor, LMCache** for CPU serving and KV cache in Phase 3
- **vLLM and RunPod** for GPU serving in Phase 4

The phases are a build order rather than a menu. The destination is an agent
platform: models served inside the network boundary, private data reached
through scoped MCP servers, an artifact store the operator owns, and — the part
the rest exists for — outputs scored automatically by a judge model, with those
scores feeding back into routing. Automated evaluation is what makes an agent
operable rather than demoable; it takes too many steps to check by hand, and
routing has nothing to act on until something scores it. Phase 1 builds the
gateway and trace pipeline everything after it plugs into, because closing that
loop needs one point that both measures a request and decides where it goes.

The current runnable target is a single-node Docker Compose deployment.
`stack.yaml` is the source of truth for layers, models, profiles, credential
names, and deployment targets.

[Documentation](https://litkhai.github.io/llmops-in-a-box/) ·
[Getting started](https://litkhai.github.io/llmops-in-a-box/getting-started/)

## Current status

| Scope | Target | Status |
|---|---|---|
| Phase 1 — gateway, UI, tracing | Docker or EC2 | Runnable |
| OpenAI / Anthropic requests through LiteLLM | — | Requires at least one provider key |
| Image generation (Cloudflare Workers AI FLUX.1-schnell) | — | Runnable; free-tier tokens optional |
| LiteLLM → Langfuse tracing | — | Runnable |
| Phase 2 — MCP tool layer (ClickHouse Cloud) | EC2 | Runnable |
| Phase 3 — CPU serving and MinIO KV cache | EC2 | Not built yet |
| Phase 4 — GPU serving on RunPod | EC2 + RunPod | Not built yet |
| Phase 5 — Operating recipes | EC2 | Not built yet |

If Langfuse traces are missing, a `LANGFUSE_MIGRATION_V4_WRITE_MODE` incompatibility in Langfuse v4 RC builds may be the cause — see [Deployment troubleshooting](https://litkhai.github.io/llmops-in-a-box/deployment/#troubleshooting) for details.

Phase 1 sends model requests to an external provider. It demonstrates the
gateway and observability architecture; it is not an air-gapped deployment.
`--profile airgapped` becomes meaningful in Phase 3, when CPU-served `qwen-0.5b`
makes the boundary real rather than configured.

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
        │                                       ClickHouse · Postgres · Redis · MinIO
        ├─ auto · English/CJK text ──▶ qwen-7b (RunPod Serverless)
        ├─ auto · Korean text   ──▶ claude-sonnet
        ├─ auto · image keywords ─▶ Cloudflare FLUX.1-schnell  (p.1)
        │                  stores ─▶ MinIO → media.<domain>
        ├─▶ MCP tools (ClickHouse Cloud)         phase 2
        ├─▶ llama.cpp CPU (qwen-0.5b)            phase 3
        │        └─▶ MinIO AIStor                phase 3
        │            datasets · artifacts · weights · KV cache
        └─▶ vLLM on RunPod (qwen-7b)             phase 4
```

Phase 1 runs today. One model alias (`auto`) in the chat UI routes to the right
provider: English/CJK text → qwen-7b (RunPod Serverless), Korean → claude-sonnet,
image-intent messages → Cloudflare Workers AI FLUX.1-schnell — all via
`UnifiedRouter`, which logs completion calls to Langfuse via the custom SDK
(routing decisions and MCP tool-result spans included).

Phase 2 is also runnable. ClickHouse Cloud is exposed as an MCP server wired
directly into the LiteLLM gateway, so every tool call is traced alongside the
model calls that triggered it. No client-side wiring required.

Applications use one OpenAI-compatible endpoint. LiteLLM resolves the model
alias; `UnifiedRouter` logs completion calls directly to Langfuse via the SDK,
so only meaningful model calls appear in traces rather than management API noise.
The model catalog is
rendered from `stack.yaml` into both LiteLLM and LibreChat configuration.
Adding a later layer changes gateway configuration, not client code.

## Build-out

| Phase | Outcome | Target | Status |
|:--:|---|---|---|
| 1 | Gateway, UI, and tracing over frontier APIs | Docker or EC2 | Runnable |
| 2 | MCP tool layer, starting with ClickHouse Cloud | EC2 | Runnable |
| 3 | CPU serving (llama.cpp) and MinIO KV cache | EC2 | Not built yet |
| 4 | GPU serving on RunPod | EC2 + RunPod | Not built yet |
| 5 | Routing, agents, guardrails, and judge-scored routing | EC2 | Not built yet |

Phase 1 runs locally with `--target docker` or on `--target aws-ec2`. Phase 2
and above require EC2: CPU inference needs the instance's CPUs, and RunPod is
an external service regardless of where the gateway lives.

See [Build-out phases](https://litkhai.github.io/llmops-in-a-box/phases/) for
the end state, the acceptance criteria of each phase, and why the order is what
it is.

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
