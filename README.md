# Sovereign AI Stack

> **A composable, self-hosted enterprise AI stack — model serving, unified gateway, chat UI, and full-stack observability, built on open infrastructure.**
>
> Stack components may include: LiteLLM · LibreChat · Langfuse · vLLM · OpenAI · Anthropic · RunPod · AWS · MinIO

---

## Why this exists

Enterprises adopting GenAI face the same set of questions:

- *Can we run our own models on our own infrastructure?* (data residency, network isolation, regulatory compliance)
- *Can we mix self-hosted models with commercial APIs (OpenAI, Anthropic) without rewriting applications?*
- *Can we see everything — every prompt, latency, token, cost, and failure — in one place?*

This repository is a **reference architecture + deployment scripts** that answers all three with open-source building blocks. Layers are fixed; implementations are swappable.

```
┌─ UI ─────────────── LibreChat
├─ Observability ──── Langfuse (backed by ClickHouse)
├─ Gateway ────────── LiteLLM (unified routing, cost tracking)
├─ Tools ──────────── MCP servers            (planned)
├─ Serving ────────── vLLM
├─ Models ─────────── Self-hosted (Qwen, EXAONE, ...) / OpenAI / Anthropic
├─ Compute ────────── RunPod / AWS
├─ Memory / Cache ─── MemKV                  (planned)
└─ Storage ────────── MinIO                  (planned)
```

---

## Architecture & Request Flow

```
                        ┌──────────────────────────────┐
                        │         End Users            │
                        └──────┬───────────────┬───────┘
                               │               │
                     Chat UI   │               │  Apps / SDKs
                               ▼               ▼
                        ┌──────────┐    ┌─────────────────┐
                        │ LibreChat│    │ OpenAI-compatible│
                        │  (UI)    │    │  client code     │
                        └────┬─────┘    └───────┬─────────┘
                             │                  │
                             ▼                  ▼
                   ┌─────────────────────────────────────┐
                   │         LiteLLM Gateway :4000       │
                   │  • single OpenAI-compatible API     │
                   │  • model routing / virtual keys     │
                   │  • cost tracking per model/team     │
                   │  • success/failure → Langfuse       │
                   └───────┬──────────┬──────────┬───────┘
                           │          │          │
              self-hosted  │          │          │  commercial APIs
                           ▼          ▼          ▼
                  ┌────────────┐ ┌─────────┐ ┌───────────┐
                  │ vLLM :8000 │ │ OpenAI  │ │ Anthropic │
                  │ Qwen2.5-7B │ │  API    │ │    API    │
                  │ on RunPod  │ └─────────┘ └───────────┘
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
                   │  Postgres (metadata) · Redis · S3   │
                   └─────────────────────────────────────┘
```

**A single request, end to end:**

1. A user sends a message in LibreChat (or any OpenAI-compatible client) and selects a model — `qwen-7b`, `gpt-4o`, or `claude-sonnet`.
2. LiteLLM receives the request on one unified endpoint, resolves the model alias, and routes it:
   - `qwen-7b` → vLLM on a RunPod GPU pod (self-hosted, OpenAI-compatible)
   - `gpt-4o` → OpenAI API
   - `claude-sonnet` → Anthropic API (format translation handled by LiteLLM)
3. The response streams back to the user.
4. LiteLLM's success/failure callbacks push the full trace — prompt, completion, latency, token counts, computed cost — into **Langfuse**, where ClickHouse stores and serves high-volume trace analytics.
5. In the Langfuse UI you compare models side by side, build datasets from production traces, and score outputs.

**Zero application code changes.** Observability lives at the gateway layer, so any framework (raw SDK, LangChain, LlamaIndex, ...) is traced identically.

---

## Repository layout

```
.
├── README.md
├── .env.example                # all API keys & endpoints in one place
├── docker/                     # Option 1 — single-node Docker Compose
│   ├── docker-compose.yml      # LiteLLM + Langfuse (CH/PG/Redis/MinIO) + LibreChat
│   ├── litellm_config.yaml
│   └── librechat.yaml
├── terraform/                  # Option 2 — AWS EC2 with Terraform
│   ├── main.tf                 # VPC, EC2, security groups, EIP
│   ├── variables.tf
│   ├── outputs.tf
│   └── user_data.sh            # cloud-init: docker compose bootstrap
├── runpod/                     # GPU serving layer
│   ├── deploy_vllm.md          # RunPod vLLM template guide
│   └── start_vllm.sh           # manual pod bootstrap script
├── scripts/
│   ├── demo.py                 # 3-model comparison demo
│   ├── healthcheck.sh          # verify all endpoints before a demo
│   └── seed_traces.py          # generate sample traffic incl. one failure
└── docs/
    └── demo-flow.md            # 10-minute demo script
```

---

## Deployment

### Prerequisites

- API keys (all optional except the ones you want to demo): `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`
- A [RunPod](https://runpod.io) account for self-hosted GPU serving (or skip and use APIs only)
- Docker ≥ 24 with Compose v2 (Option 1) / Terraform ≥ 1.7 + AWS credentials (Option 2)

```bash
cp .env.example .env
# fill in your keys
```

### Step 0 — Serving layer: vLLM on RunPod

Deploy via RunPod's **vLLM Quick Deploy template** (recommended) or manually on any GPU pod:

```bash
# on the pod (1× A40 / L40S is enough for a 7B model)
pip install vllm
vllm serve Qwen/Qwen2.5-7B-Instruct --port 8000 --api-key ${VLLM_API_KEY}
```

Expose port 8000 through RunPod's HTTP proxy and note the endpoint:

```
https://<pod-id>-8000.proxy.runpod.net/v1
```

Put it into `.env` as `VLLM_API_BASE`. See [`runpod/deploy_vllm.md`](runpod/deploy_vllm.md) for details, model alternatives (EXAONE, EEVE for Korean workloads), and proxy timeout notes.

### Option 1 — Docker on a laptop (single node)

Everything except GPU serving runs locally in one compose stack:

```bash
cd docker
docker compose up -d
```

| Service | URL | Notes |
|---|---|---|
| LibreChat | http://localhost:3080 | chat UI, model picker |
| LiteLLM | http://localhost:4000 | unified gateway |
| Langfuse | http://localhost:3000 | observability UI |
| ClickHouse | localhost:8123 | Langfuse trace store |
| MinIO | http://localhost:9001 | S3-compatible blob store for Langfuse |

First-time setup:

1. Open Langfuse → create org/project → copy public & secret keys into `.env`
2. `docker compose restart litellm` so callbacks pick up the keys
3. Run the smoke test:

```bash
./scripts/healthcheck.sh
python scripts/demo.py        # sends prompts to all three models
```

Open Langfuse — you should see traces for `qwen-7b`, `gpt-4o`, and `claude-sonnet` in one project.

### Option 2 — AWS EC2 with Terraform

Provisions a single EC2 instance (default `t3.xlarge`, gp3 volume), security groups, and an Elastic IP, then bootstraps the same compose stack via cloud-init:

```bash
cd terraform
terraform init
terraform apply \
  -var="key_name=<your-keypair>" \
  -var="allowed_cidr=<your-ip>/32"
```

Outputs the public endpoints:

```
librechat_url = http://<eip>:3080
litellm_url   = http://<eip>:4000
langfuse_url  = http://<eip>:3000
```

Notes:

- The security group restricts inbound to `allowed_cidr` — do not open to `0.0.0.0/0` for a demo stack with real API keys.
- For production hardening: put an ALB + ACM cert in front, move Postgres to RDS, ClickHouse to ClickHouse Cloud, and secrets to SSM Parameter Store.
- `terraform destroy` tears everything down; RunPod pods are billed separately — stop them in the RunPod console.

### Gateway configuration (both options)

`docker/litellm_config.yaml`:

```yaml
model_list:
  # 1. Self-hosted (RunPod vLLM)
  - model_name: qwen-7b
    litellm_params:
      model: openai/Qwen/Qwen2.5-7B-Instruct
      api_base: os.environ/VLLM_API_BASE
      api_key: os.environ/VLLM_API_KEY

  # 2. OpenAI
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY

  # 3. Anthropic
  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-sonnet-4-5
      api_key: os.environ/ANTHROPIC_API_KEY

litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]
```

Client code is identical for every model:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000", api_key="sk-litellm-master")

for m in ["qwen-7b", "gpt-4o", "claude-sonnet"]:
    r = client.chat.completions.create(
        model=m,
        messages=[{"role": "user", "content": "Explain ClickHouse in one sentence."}],
    )
    print(m, "→", r.choices[0].message.content)
```

---

## Demo flow (10 minutes)

1. **Serving** — show the RunPod pod running vLLM: *your model, your infra, live in minutes.*
2. **Traffic** — run `scripts/seed_traces.py` (or chat in LibreChat): 3–4 prompts across all three models, including one long generation and one deliberate failure so error traces appear.
3. **Observability** — open Langfuse: traces → latency/token/cost comparison per model → sessions → create a dataset from a trace and score one output.
4. **Close** — Langfuse v3 runs on ClickHouse; at production trace volumes this is exactly the high-cardinality OLAP workload it was built for.

Full script with talking points: [`docs/demo-flow.md`](docs/demo-flow.md).

---

## What this demonstrates

**Deployment & operations**

- **Ease of deployment** — vLLM template on RunPod is live in minutes vs. EC2 GPU setup (AMI, drivers, networking); the rest of the stack is one `docker compose up` or one `terraform apply`.
- **Fast cold-start** — RunPod pods spin up in seconds (FlashBoot for serverless) vs. minutes-long cloud GPU provisioning.
- **Cost efficiency** — per-second GPU billing with zero idle cost when stopped; typically 2–3× cheaper than on-demand cloud GPU pricing. LiteLLM cost tracking makes self-hosted vs. API economics directly comparable in Langfuse.

**Architecture**

- **Unified gateway** — one OpenAI-compatible endpoint in front of self-hosted and commercial models; applications never change when models do.
- **Framework-neutral observability** — tracing lives at the gateway, so raw SDKs, LangChain, LlamaIndex, and future MCP-based agents are all captured identically with zero app-code changes.
- **Composability** — every layer is swappable: vLLM → SGLang/TGI, RunPod → AWS/on-prem GPU, LibreChat → your own app, without touching the rest of the stack.

**Enterprise fit**

- **Sovereignty & compliance** — the full path (UI → gateway → model → traces) can run inside your own network boundary; relevant to regulated and air-gapped environments (e.g. Korean 망분리 / ISMS-P contexts).
- **Gradual adoption** — start with commercial APIs, add self-hosted models later (or vice versa) behind the same gateway, with one observability pane throughout.
- **Scale story** — Langfuse's ClickHouse backend handles production-scale trace volume; the same architecture extends from a laptop demo to millions of traces per day.

---

## Roadmap

- [ ] **MCP tool layer** — expose enterprise tools to agents via MCP servers, traced through the same pipeline
- [ ] **MinIO storage layer** — datasets, artifacts, and model weights on S3-compatible object storage
- [ ] **MemKV memory/cache layer** — semantic caching and conversation memory
- [ ] **Agent demo** — a multi-step agent (tool-use loop) producing nested traces in Langfuse
- [ ] **Eval pipeline** — LLM-as-judge scoring on Langfuse datasets, scheduled
- [ ] **Kubernetes profile** — Helm-based deployment for production environments

---

## FAQ

**Do I need LangChain?** No. Observability is captured at the gateway (LiteLLM → Langfuse callbacks), so this works with any client. LangChain/LangGraph apps are also traced automatically if you use them.

**Can I skip RunPod?** Yes — comment out the `qwen-7b` entry and demo with OpenAI/Anthropic only. Or point `VLLM_API_BASE` at any OpenAI-compatible endpoint (on-prem vLLM, AWS EC2 GPU, SGLang).

**Can I self-host Langfuse fully air-gapped?** Yes — Option 1's compose stack has no external dependencies beyond the model endpoints you configure.

## License

MIT