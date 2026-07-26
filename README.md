# LLMOPS In a Box
## Sovereign AI Stack

> **A composable, self-hosted enterprise AI stack — model serving, unified gateway, chat UI, and full-stack observability, built on open infrastructure.**
>
> Stack components may include: LiteLLM · LibreChat · Langfuse · vLLM · OpenAI · Anthropic · RunPod · AWS · MinIO

📖 **[Documentation site →](https://litkhai.github.io/llmops-in-a-box/)**

| | |
|---|---|
| [**Background**](https://litkhai.github.io/llmops-in-a-box/background/) | why a gateway is the load-bearing decision, what was considered at each layer, why ClickHouse sits under Langfuse, what 망분리 / ISMS-P require, and a glossary |
| [**Build-out phases**](https://litkhai.github.io/llmops-in-a-box/phases/) | the build order, what each phase proves, and what is deliberately not scheduled |
| [**Configuration**](https://litkhai.github.io/llmops-in-a-box/configuration/) | how one `stack.yaml` and one script describe the whole stack |
| [**Deployment**](https://litkhai.github.io/llmops-in-a-box/deployment/) | laptop and EC2, prerequisites, troubleshooting |
| [**Credentials**](https://litkhai.github.io/llmops-in-a-box/credentials/) | every key, its scope, owner and rotation cadence |
| [**Demo flow**](https://litkhai.github.io/llmops-in-a-box/demo-flow/) | a ten-minute walkthrough with talking points |

---

## Why this exists

Enterprises adopting GenAI face the same set of questions:

- *Can we run our own models on our own infrastructure?* (data residency, network isolation, regulatory compliance)
- *Can we mix self-hosted models with commercial APIs (OpenAI, Anthropic) without rewriting applications?*
- *Can we see everything — every prompt, latency, token, cost, and failure — in one place?*

This repository is a **reference architecture + deployment scripts** that answers all three with open-source building blocks. Layers are fixed; implementations are swappable.

```
┌─ UI ─────────────── LibreChat                        Phase 1
├─ Observability ──── Langfuse (backed by ClickHouse)   Phase 1
├─ Gateway ────────── LiteLLM (routing, cost tracking)  Phase 1
├─ Models ─────────── OpenAI / Anthropic                Phase 1
├─ Tools ──────────── MCP servers (ClickHouse Cloud)    Phase 2
├─ Serving ────────── vLLM                              Phase 3
├─ Models ─────────── Self-hosted (Qwen, EXAONE, ...)   Phase 3
├─ Compute ────────── RunPod / AWS                      Phase 3
├─ Storage ────────── MinIO AIStor — datasets/evals/weights Phase 4
│                     (object store: free at one node)
└─ KV cache ───────── LMCache — reuse a long shared prefix  Phase 4a
                      (in-process with vLLM, not a container)

   Operating recipes ─ context routing · agents · evals      Phase 5
   (no new layers — things to do with the stack above)
```

---

## Build-out phases

The stack is built **frontier-first**: get the gateway, tracing, and UI working against commercial APIs, then add tools, then self-hosting, then storage — and finally the operating recipes that only make sense once all of it is running. Each phase is a one-flag change — no config rewrite.

| Phase | Scope | Adds | Status |
|:--:|---|---|---|
| **1** | **Frontier models** — LiteLLM + Langfuse + LibreChat against OpenAI and Anthropic. No GPU required. | `gateway`, `observability`, `ui` | 🚧 in progress |
| **2** | **MCP tool layer** — MCP servers behind the gateway so tool calls are traced through the same pipeline. First server is ClickHouse Cloud — settled, not a shortlist. | `tools` | planned |
| **3** | **Self-hosted serving** — vLLM on a RunPod GPU pod alongside the APIs, in one Langfuse project. | `serving`, `qwen-7b` | planned |
| **4** | **Storage & large context** — a MinIO AIStor instance for datasets, eval artifacts and weights, separate from the blob store Langfuse runs for itself. Doubles as the offload tier for KV-cache reuse, which is what makes long shared prompts affordable. AIStor Free is single-node with no capacity limit, so the **object store** costs nothing. | `storage` | planned |
| **5** | **Operating recipes** — context-based routing in LiteLLM, LibreChat Agents over the MCP tools, Langfuse evals. Adds no layers. | — | planned |

> **On KV-cache offload, and MemKV specifically.** The capability — prefill a long shared prefix once and reuse it instead of recomputing it per request — splits into two tracks.
>
> **Buildable now (Phase 4a):** vLLM's prefix caching, then [LMCache](https://github.com/lmcache/lmcache) to move that cache off the GPU to CPU, disk or **S3-compatible storage** — which is to say, the Phase 4 AIStor instance. Runs on the existing Phase 3 pod.
>
> **Partnership track:** [MinIO MemKV](https://www.min.io/product/memkv) does the same thing at fleet scale over RDMA, and needs NVIDIA STX systems, Vera CPUs, Spectrum-X 800 GbE and PCIe Gen6. It has no GA, no trial and no download — only *"Talk to a Specialist"* and *"Get Pricing"* — so the next step there is **opening a partnership discussion with MinIO**, not an install. Note it is a separate product from AIStor: the free-at-one-node tier does **not** extend to it. See [Build-out phases](docs/phases.md).

```bash
./scripts/stack.sh phases      # which phase is current, and what each adds
```

Why this order: Phase 1 proves the *architecture* (unified gateway + gateway-level tracing) with zero infrastructure risk. Everything after it plugs into an already-working observability pipeline, so each new layer is validated against a known-good baseline instead of debugging two moving parts at once.

---

## Architecture & Request Flow

```
                        ┌──────────────────────────────┐
                        │         End Users            │
                        └──────┬───────────────┬───────┘
                               │               │
                     Chat UI   │               │  Apps / SDKs
                               ▼               ▼
                        ┌──────────┐    ┌──────────────────┐
                        │ LibreChat│    │ OpenAI-compatible│
                        │  (UI)    │    │  client code     │
                        └────┬─────┘    └───────┬──────────┘
                             │                  │
                             ▼                  ▼
                   ┌─────────────────────────────────────┐
                   │         LiteLLM Gateway :4000       │
                   │  • single OpenAI-compatible API     │
                   │  • model routing / virtual keys     │
                   │  • cost tracking per model/team     │
                   │  • success/failure → Langfuse       │
                   └───┬────────┬─────────┬─────────┬────┘
                       │        │         │         │
          Phase 1 ─────┴──┐     │    ┌────┴─ Phase 1   Phase 2 ┐
                          ▼     ▼    ▼                          ▼
                  ┌─────────┐ ┌───────────┐            ┌──────────────┐
                  │ OpenAI  │ │ Anthropic │            │  MCP servers │
                  │  API    │ │    API    │            │  (ClickHouse │
                  └─────────┘ └───────────┘            │    Cloud)    │
                                                       └──────────────┘
                       ┌────────────┐
          Phase 3 ─────│ vLLM :8000 │
                       │ Qwen2.5-7B │
                       │ on RunPod  │
                       │  GPU pod   │
                       └────────────┘

                   All traffic (input/output, latency,
                   tokens, cost, errors) is traced to:

                   ┌─────────────────────────────────────┐
                   │        Langfuse :3000               │
                   │  traces · sessions · datasets ·     │
                   │  evals · prompt management          │
                   │  ──────────────────────────────     │
                   │  ClickHouse (OLAP trace storage)    │
                   │  Postgres (metadata) · Redis · MinIO│
                   └─────────────────────────────────────┘
```

**A single request, end to end:**

1. A user sends a message in LibreChat (or any OpenAI-compatible client) and selects a model — `gpt-4o`, `claude-sonnet`, or (from Phase 3) `qwen-7b`.
2. LiteLLM receives the request on one unified endpoint, resolves the model alias, and routes it:
   - `gpt-4o` → OpenAI API
   - `claude-sonnet` → Anthropic API (format translation handled by LiteLLM)
   - `qwen-7b` → vLLM on a RunPod GPU pod (self-hosted, OpenAI-compatible) *(Phase 3)*
3. The response streams back to the user.
4. LiteLLM's success/failure callbacks push the full trace — prompt, completion, latency, token counts, computed cost — into **Langfuse**, where ClickHouse stores and serves high-volume trace analytics.
5. In the Langfuse UI you compare models side by side, build datasets from production traces, and score outputs.

**Zero application code changes.** Observability lives at the gateway layer, so any framework (raw SDK, LangChain, LlamaIndex, ...) is traced identically.

---

## Configuration model

One declarative file describes **what** the stack is. A script decides **where** it runs.

```
                    stack.yaml
        (layers · models · phases · secrets refs)
                        │
                        │  ./scripts/stack.sh
                        │
        ┌───────────────┼────────────────┐
        │               │                │
        ▼               ▼                ▼
  resolve layers    render model      pick target
  → compose          catalog          → docker
    profiles         → litellm_config   → aws-ec2
                     → librechat.yaml
```

**`stack.yaml`** is the single source of truth: layers and their implementations, the model catalog, build-out phases, deployment targets, and the *names* of every secret. It never contains a secret value and never mentions a specific host.

**`scripts/stack.sh`** resolves that config for a chosen `--target` and `--profile`, then renders the model catalog into the two configs that would otherwise duplicate it — LiteLLM's `model_list` and LibreChat's model picker. Add a model in one place, and the gateway and the UI both learn about it.

`docker-compose.yml` stays hand-written and greppable; layer selection maps onto native **compose profiles**.

### Commands

```bash
./scripts/stack.sh doctor                       # preflight: tooling, secrets, layers, models
./scripts/stack.sh secrets write|gen|audit      # credential inventory -> .env, leak check
./scripts/stack.sh phases                       # build-out phases and current status
./scripts/stack.sh config                       # resolved stack for the selected target/profile
./scripts/stack.sh models                       # model table with per-1k costs
./scripts/stack.sh render                       # regenerate litellm_config.yaml + librechat.yaml
./scripts/stack.sh up      --target docker      # render, then deploy
./scripts/stack.sh urls                         # print every endpoint, no requests
./scripts/stack.sh status                       # curl every health check for active layers
./scripts/stack.sh logs                         # follow compose logs
./scripts/stack.sh down    [--purge]            # tear down (--purge also drops volumes)
```

Flags: `--target`/`-t` · `--profile`/`-p` · `--file`/`-f` · `--tf-var k=v` · `--all` · `--no-render` · `--purge` · `--dry-run`/`-n` · `--help`/`-h`

### Profiles

Profiles select which layers and models come up. The `phase-N` profiles are cumulative.

| Profile | Layers | Models |
|---|---|---|
| `phase-1` *(default)* | gateway, observability, ui | `gpt-4o`, `claude-sonnet` |
| `phase-2` | + tools | `gpt-4o`, `claude-sonnet` |
| `phase-3` | + serving | + `qwen-7b` |
| `phase-4` | + storage, memory | all |
| `headless` | gateway, observability | all enabled |
| `airgapped` | gateway, observability, ui, serving | `qwen-7b` only — no egress |

```bash
./scripts/stack.sh up --profile headless    # SDK demos, no chat UI
./scripts/stack.sh up --profile airgapped   # no commercial API egress
```

Layer dependencies resolve transitively — asking for a layer brings up what it needs. Profiles that reference a not-yet-built layer warn and skip it rather than failing.

---

## Repository layout

```
.
├── AGENTS.md                   # ★ repository guidance for Codex collaboration
├── stack.yaml                  # ★ single source of truth — layers, models, phases
├── .env.example                # secret NAMES with per-phase grouping
├── .gitignore                  # + .dockerignore, .cursorignore, .aiignore,
│                               #   .aiexclude, .codeiumignore, .aiderignore,
│                               #   .continueignore, .geminiignore, .codexignore
├── .claude/settings.json       # denies Claude Code `Read` on secrets/
├── secrets/                    # ★ credential inventory (contents ignored)
│   ├── README.md               # setup, ignore coverage, leak response
│   └── credentials.example.yaml # template — committed, value-free
├── scripts/
│   ├── stack.sh                # ★ control plane: doctor / render / up / down / status
│   ├── demo.py                 # 3-model comparison demo              (todo)
│   ├── healthcheck.sh          # superseded by `stack.sh status`      (todo)
│   └── seed_traces.py          # sample traffic incl. one failure     (todo)
├── docker/                     # Target 1 — single-node Docker Compose
│   ├── docker-compose.yml      # LiteLLM + Langfuse + LibreChat       (todo)
│   ├── litellm_config.yaml     # ⚙ RENDERED from stack.yaml
│   └── librechat.yaml          # ⚙ RENDERED from stack.yaml
├── terraform/                  # Target 2 — AWS EC2                   (todo)
├── runpod/                     # Phase 3 — GPU serving layer          (todo)
├── mkdocs.yml                  # ★ docs site (MkDocs Material)
├── requirements-docs.txt
├── .github/workflows/pages.yml # ★ builds + deploys the site
└── docs/                       # ★ published to GitHub Pages
    ├── index.md                # overview + architecture
    ├── phases.md               # the 4-phase build-out
    ├── configuration.md        # stack.yaml + stack.sh
    ├── deployment.md           # targets, prerequisites, troubleshooting
    ├── credentials.md          # secret handling and ignore coverage
    └── demo-flow.md            # 10-minute demo script
```

★ implemented · ⚙ generated, do not hand-edit · (todo) not scaffolded yet

---

## Credentials

Every API key the stack touches — OpenAI, Anthropic, RunPod, AWS, ClickHouse Cloud, Langfuse, MinIO — is inventoried in **one** private file: `secrets/credentials.yaml`. The phase-aware wizard updates it with hidden input; `.env` is generated from it.

```
secrets/credentials.yaml  ──secrets write──►  .env  ──►  compose / terraform
      (private, 0600)                   (generated, 0600)
```

Each entry records more than the value — the console URL to get it, the scopes it needs, the owner, and a rotation cadence:

```yaml
- name: ClickHouse Cloud user
  phase: 2
  env: CLICKHOUSE_CLOUD_USER
  value: ""
  console: https://clickhouse.cloud → service → Settings → Users
  scopes: [SELECT]
  notes: >-
    Create a dedicated READ-ONLY user for the MCP server. An agent with a
    tool has the user's full grants — do not reuse the admin account.
  rotates: 90d
```

```bash
./scripts/stack.sh secrets setup           # select a phase; enter external keys
./scripts/stack.sh secrets status --all    # no values printed
./scripts/stack.sh secrets validate --all  # offline format checks
./scripts/stack.sh secrets write           # credentials.yaml -> .env
./scripts/stack.sh secrets audit           # verify nothing can leak
```

### Ignore coverage

`secrets/credentials.yaml` and `.env` are excluded from git, from Docker build contexts, and from every AI coding tool's index:

| Tool | Mechanism | File |
|---|---|---|
| Git | ignore rules | `.gitignore` |
| Docker | build-context exclusion | `.dockerignore` |
| Claude Code | `permissions.deny` on `Read` | `.claude/settings.json` |
| Cursor | ignore rules | `.cursorignore` |
| JetBrains AI Assistant | ignore rules | `.aiignore` |
| Gemini Code Assist | ignore rules | `.aiexclude`, `.geminiignore` |
| Codeium / Windsurf | ignore rules | `.codeiumignore` |
| Aider | ignore rules | `.aiderignore` |
| Continue | ignore rules | `.continueignore` |
| OpenAI Codex CLI | honours `.gitignore`; `.codexignore` as belt-and-braces | `.codexignore` |

`secrets audit` verifies all of the above, plus that neither file is in the index **or anywhere in git history**, and that the committed template is still value-free. Run it before committing anything under `secrets/`.

> **GitHub Copilot is the exception.** It has no repo-level ignore file — content exclusions are server-side, under *Settings → Copilot → Content exclusions*. Add `secrets/**`, `.env`, and `**/*.tfvars` there. Until you do, assume Copilot can see these files.

If a credential does leak, **revoke at the provider first** — rewriting history is not containment. See [`secrets/README.md`](secrets/README.md).

---

## Deployment

### Prerequisites

- `yq` (mikefarah v4) — `brew install yq`
- Docker ≥ 24 with Compose v2 *(target: `docker`)*, or Terraform ≥ 1.7 + AWS credentials *(target: `aws-ec2`)*
- API keys for the models you want: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`

`scripts/stack.sh` targets bash 3.2, so macOS system bash works with no upgrade.

```bash
./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup          # choose a phase; enter external keys
./scripts/stack.sh secrets generate --phase 1  # optional local values
./scripts/stack.sh secrets write          # generate .env (mode 600)
./scripts/stack.sh doctor
```

`doctor` only checks the secrets the selected profile actually needs — in Phase 1 it stays quiet about RunPod and MCP credentials. Use `--all` to see every phase.

See [Credentials](#credentials) for the full inventory and how it stays out of git and AI tool indexes.

### Target 1 — Docker on a laptop (single node)

```bash
./scripts/stack.sh up --target docker --profile phase-1
```

| Service | URL | Notes |
|---|---|---|
| LibreChat | http://localhost:3080 | chat UI, model picker |
| LiteLLM | http://localhost:4000 | unified gateway |
| Langfuse | http://localhost:3000 | observability UI |
| ClickHouse | localhost:8123 | Langfuse trace store |
| MinIO | http://localhost:9001 | blob store backing Langfuse |

> ⚠️ **`up` exits 1 today** — `docker/docker-compose.yml` has not been written, and writing it *is* Phase 1. See [Pre-Phase-1 confirmation](https://litkhai.github.io/llmops-in-a-box/phases/#pre-phase-1-confirmation).

First-time setup — prefer [Langfuse headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization), which lets you choose the key pair up front via `LANGFUSE_INIT_*` so the stack comes up correctly in one pass. Otherwise, the manual route:

1. Open Langfuse → create org/project → copy the public & secret keys into **`secrets/credentials.yaml`**, then `./scripts/stack.sh secrets write`
2. `./scripts/stack.sh up` again — LiteLLM restarts and picks up the callback keys
3. Verify: `./scripts/stack.sh status`

Never paste secrets into `.env` directly — it is generated from `secrets/credentials.yaml` and overwritten on every `secrets write`.

Open Langfuse — you should see traces for `gpt-4o` and `claude-sonnet` in one project.

### Target 2 — AWS EC2 with Terraform

Provisions a single EC2 instance (default `t3.xlarge`, gp3 volume), security groups, and an Elastic IP, then bootstraps the same compose stack via cloud-init:

```bash
./scripts/stack.sh up --target aws-ec2 \
  --tf-var key_name=<your-keypair> \
  --tf-var allowed_cidr=<your-ip>/32
```

Instance type, volume size, and region come from `targets.aws-ec2.vars` in `stack.yaml`; `--tf-var` overrides or adds. The host for `status` and `urls` is read from the `public_ip` terraform output, so no IP is ever hard-coded.

Notes:

- The security group restricts inbound to `allowed_cidr` — **do not** open to `0.0.0.0/0` for a demo stack holding real API keys.
- For production hardening: ALB + ACM cert in front, Postgres → RDS, ClickHouse → ClickHouse Cloud, secrets → SSM Parameter Store.
- `./scripts/stack.sh down --target aws-ec2` runs `terraform destroy`. From Phase 3 on, RunPod pods are billed separately — stop them in the RunPod console.

### Adding a model

Add one entry to `models:` in `stack.yaml`, then re-render. Both LiteLLM and the LibreChat picker update together:

```yaml
- alias: gpt-4o-mini
  phase: 1
  enabled: true
  tier: commercial
  provider: openai
  litellm_model: openai/gpt-4o-mini
  api_key_env: OPENAI_API_KEY
  context_window: 128000
  cost_per_1k: { input: 0.00015, output: 0.0006 }
  ui:
    label: GPT-4o mini
    description: Cheap, fast baseline for cost comparisons.
```

```bash
./scripts/stack.sh render && ./scripts/stack.sh up
```

Costs are written per **1,000 tokens** for readability; the renderer converts them to LiteLLM's per-token fields so Langfuse cost attribution is correct.

### Client code

Identical for every model, in every phase:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000", api_key="sk-litellm-master")

for m in ["gpt-4o", "claude-sonnet"]:          # add "qwen-7b" from Phase 3
    r = client.chat.completions.create(
        model=m,
        messages=[{"role": "user", "content": "Explain ClickHouse in one sentence."}],
    )
    print(m, "→", r.choices[0].message.content)
```

---

## Phase 3 — vLLM on RunPod

Not required to run the stack today. When Phase 3 starts, deploy via RunPod's **vLLM Quick Deploy template** (recommended) or manually on any GPU pod:

```bash
# on the pod (1× A40 / L40S is enough for a 7B model)
pip install vllm
vllm serve Qwen/Qwen2.5-7B-Instruct --port 8000 --api-key ${VLLM_API_KEY}
```

Expose port 8000 through RunPod's HTTP proxy and put the endpoint in `.env` as `VLLM_API_BASE` (note the `/v1` suffix):

```
https://<pod-id>-8000.proxy.runpod.net/v1
```

Then switch profile — no config rewrite:

```bash
./scripts/stack.sh up --profile phase-3
```

`stack.yaml` also declares a `qwen-7b → gpt-4o` fallback, so a cold or stopped pod degrades to an API model instead of erroring. The renderer prunes that fallback automatically when the target model isn't in the active profile (e.g. under `airgapped`).

Model alternatives for Korean workloads are listed under `layers.serving.options.alternatives` (EXAONE-3.5, EEVE-Korean).

---

## Demo flow (10 minutes)

1. **Config** — `./scripts/stack.sh config` and `phases`: one file describes the stack, the script picks the target. *Layers are fixed; implementations are swappable.*
2. **Traffic** — chat in LibreChat across both models, including one long generation and one deliberate failure so error traces appear.
3. **Observability** — open Langfuse: traces → latency/token/cost comparison per model → sessions → create a dataset from a trace and score one output.
4. **Close** — Langfuse v3 runs on ClickHouse; at production trace volumes this is exactly the high-cardinality OLAP workload it was built for.

From Phase 3, open with the RunPod pod running vLLM: *your model, your infra, live in minutes.*

Full script with talking points: **[docs/demo-flow.md](https://litkhai.github.io/llmops-in-a-box/demo-flow/)**.

---

## What this demonstrates

Each claim is tagged with the phase that makes it **showable**. Most are not showable yet — three of the four operational claims are about GPU economics, and Phase 1 has no GPU in it.

> ⚠️ A `Phase 3` claim is an argument about the design, not something that can be put on screen today. Leading with GPU cost figures against a stack that is currently OpenAI and Anthropic only is what gets taken apart in the room.

**Deployment & operations**

- `Phase 1` **Config-driven deployment** — one `stack.yaml` plus one script covers laptop and cloud; the deployment target is a flag, not a fork in the config tree.
- `Phase 1` **Cross-provider cost attribution** — LiteLLM reports per-model cost into Langfuse, so OpenAI and Anthropic spend sits on one axis. The half of the cost story that works with no GPU.
- `Phase 3` **Ease of deployment** — vLLM template on RunPod is live in minutes vs. EC2 GPU setup (AMI, drivers, networking); the rest is one `stack.sh up`.
- `Phase 3` **Fast cold-start** — RunPod pods spin up in seconds (FlashBoot for serverless) vs. minutes-long cloud GPU provisioning.
- `Phase 3` **GPU cost efficiency** — per-second billing with zero idle cost when stopped; typically 2–3× cheaper than on-demand cloud GPU pricing. The *self-hosted vs. API* comparison needs a self-hosted model to compare against, so it arrives with this phase, not before.

**Architecture**

- `Phase 1` **Unified gateway** — one OpenAI-compatible endpoint in front of self-hosted and commercial models; applications never change when models do.
- `Phase 1` **Framework-neutral observability** — tracing lives at the gateway, so raw SDKs, LangChain and LlamaIndex are captured identically with zero app-code changes.
- `Phase 2` **Traced tool calls** — the same applies to MCP-based agents: tool calls land in Langfuse beside the completion that triggered them.
- `Phase 3` **Composability** — every layer is swappable: vLLM → SGLang/TGI, RunPod → AWS/on-prem GPU, LibreChat → your own app. Swapping the serving layer only becomes a demonstration once there is one.
- `Phase 3` **Incremental adoption** — the phase profiles are the argument, and it completes when the same config has actually carried the stack from APIs-only to self-hosted without a rewrite.

**Enterprise fit**

- `Phase 1` **Scale story** — Langfuse's ClickHouse backend handles production-scale trace volume; the same architecture extends from a laptop demo to millions of traces per day.
- `Phase 1` **Gradual adoption** — start with commercial APIs behind the gateway, with one observability pane from the first request.
- `Phase 3` **Sovereignty & compliance** — the full path (UI → gateway → model → traces) inside your own network boundary; relevant to regulated and air-gapped environments (e.g. Korean 망분리 / ISMS-P contexts). `--profile airgapped` enforces no commercial API egress — but it needs a self-hosted model to route to, so **Phase 1 egresses every request to OpenAI or Anthropic**. Say so plainly rather than letting the architecture diagram imply otherwise.

---

## Roadmap

Tracked as phases in [`stack.yaml`](stack.yaml) — see `./scripts/stack.sh phases`.

- [ ] **Phase 1** — `docker-compose.yml`, `demo.py`, `seed_traces.py`
- [ ] **Phase 2** — MCP tool layer; ClickHouse Cloud server first, traced through the same pipeline
- [ ] **Phase 3** — RunPod vLLM serving; `runpod/deploy_vllm.md`, `terraform/`
- [ ] **Phase 4** — MinIO AIStor artifact store (`datasets`, `artifacts`, `weights`), single node
- [ ] **Phase 5** — operating recipes over Phases 1–4, no new layers:
  - [ ] context-based routing in LiteLLM (`context_window_fallbacks`), verified in the Langfuse cost report
  - [ ] a LibreChat Agent driving the ClickHouse MCP server, producing nested tool-call traces
  - [ ] Langfuse evals — LLM-as-judge over a dataset built from real traces, scored across all three models
- **Not scheduled** — recorded so the research isn't repeated, deliberately not build targets:
  - *MemKV* — KV-cache offload. Plan only: no GA, no download or trial, no ship date, and dependent on unreleased NVIDIA STX hardware. Not a purchase-order problem
  - *Semantic cache* — a different mechanism; LiteLLM does it natively with Redis and would want its own layer, not `memory`'s name
  - *KV-cache reuse in open source* — vLLM prefix caching, [LMCache](https://github.com/lmcache/lmcache) for offload to CPU/disk/S3-compatible storage
- [ ] **Kubernetes target** — Helm profile (`targets.k8s`, currently `enabled: false`)

---

## FAQ

**Why frontier models before self-hosting?** Phase 1 validates the architecture — unified gateway, gateway-level tracing, cost attribution — with no GPU, no drivers, no cold-start latency. Once traces are flowing, adding vLLM is a one-flag change against a known-good baseline instead of debugging two new systems at once.

**Do I need LangChain?** No. Observability is captured at the gateway (LiteLLM → Langfuse callbacks), so this works with any client. LangChain/LangGraph apps are also traced automatically if you use them.

**Can I skip RunPod entirely?** Yes — that's the Phase 1 default. Or point `VLLM_API_BASE` at any OpenAI-compatible endpoint (on-prem vLLM, EC2 GPU, SGLang) and use `--profile phase-3`.

**Why is `yq` required?** `stack.sh` reads `stack.yaml` and renders the model catalog into LiteLLM and LibreChat configs. `brew install yq` — mikefarah v4; the script refuses other implementations.

**Can I hand-edit the rendered configs?** No — `render` overwrites them, and `up` renders by default. Edit `stack.yaml` instead. Use `--no-render` if you need a one-off manual override.

**Where do API keys live?** One file — `secrets/credentials.yaml`, created by `secrets init` and safely updated by the phase-aware `secrets setup` wizard. `.env` is derived from it via `./scripts/stack.sh secrets write` and should never be hand-edited. Both are ignored by git, Docker, and every AI coding tool listed under [Credentials](#credentials); `secrets audit` proves it.

**Can I self-host Langfuse fully air-gapped?** Yes — the compose stack has no external dependencies beyond the model endpoints you configure. `--profile airgapped` drops the commercial API models entirely.

## License

MIT
