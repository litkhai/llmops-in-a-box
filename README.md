# LLMOPS In a Box

A composable LLMOps reference stack built around a single gateway:

- **LiteLLM** for model routing and cost tracking
- **Langfuse** for traces, sessions, datasets, and evaluations
- **LibreChat** for the user interface
- **OpenAI and Anthropic** in the current Phase 1 stack
- **MCP, vLLM, RunPod, and MinIO AIStor** in planned phases

The current runnable target is a single-node Docker Compose deployment.
`stack.yaml` is the source of truth for layers, models, profiles, credential
names, and deployment targets.

[Documentation](https://litkhai.github.io/llmops-in-a-box/) ·
[Getting started](https://litkhai.github.io/llmops-in-a-box/getting-started/) ·
[Phase 1 workshop](https://litkhai.github.io/llmops-in-a-box/workshop/)

## Current status

| Scope | Status |
|---|---|
| Phase 1 Docker stack | Runnable |
| OpenAI / Anthropic requests through LiteLLM | Requires at least one provider key |
| LiteLLM → Langfuse tracing | Runnable |
| AWS EC2 target | Declared, Terraform not implemented |
| Phases 2–5 | Planned |

Phase 1 sends model requests to an external provider. It demonstrates the
gateway and observability architecture; it is not an air-gapped deployment.

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

```text
LibreChat / applications
          |
          v
  LiteLLM Gateway
     |         |
     v         v
  OpenAI   Anthropic
          |
          v
      Langfuse
   ClickHouse · Postgres · Redis · MinIO
```

Applications use one OpenAI-compatible endpoint. LiteLLM resolves the model
alias and sends success and failure telemetry to Langfuse. The model catalog is
rendered from `stack.yaml` into both LiteLLM and LibreChat configuration.

## Build-out

| Phase | Outcome | Status |
|:--:|---|---|
| 1 | Gateway, UI, and tracing over frontier APIs | In progress |
| 2 | MCP tool layer, starting with ClickHouse Cloud | Planned |
| 3 | vLLM self-hosted serving alongside provider APIs | Planned |
| 4 | Artifact storage and KV-cache reuse | Planned |
| 5 | Routing, agents, guardrails, and evaluation recipes | Planned |

See [Build-out phases](https://litkhai.github.io/llmops-in-a-box/phases/) for
scope and acceptance criteria. Planned components are documented as plans, not
as runnable features.

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
docker/                     runnable Phase 1 Compose target
secrets/                    credential template and local inventory
docs/                       MkDocs documentation
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
| Inspect profiles and future scope | [Build-out phases](https://litkhai.github.io/llmops-in-a-box/phases/) |
| Change layers or models | [Configuration](https://litkhai.github.io/llmops-in-a-box/configuration/) |
| Operate a deployment target | [Deployment](https://litkhai.github.io/llmops-in-a-box/deployment/) |
| Present the stack | [Demo flow](https://litkhai.github.io/llmops-in-a-box/demo-flow/) |

## License

MIT
