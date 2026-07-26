---
hide:
  - navigation
---

# Deployment

Two targets, one config. The target is a **flag**, not a fork in the config tree.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `yq` | mikefarah v4 — `brew install yq` |
| Docker ≥ 24 + Compose v2 | Target `docker` |
| Terraform ≥ 1.7 + AWS credentials | Target `aws-ec2` |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | At least one, for the models you want |

`scripts/stack.sh` targets bash 3.2, so macOS system bash works with no upgrade.

```bash
cp secrets/credentials.example.yaml secrets/credentials.yaml
./scripts/stack.sh secrets gen
$EDITOR secrets/credentials.yaml
./scripts/stack.sh secrets write
./scripts/stack.sh doctor
```

`doctor` only checks the secrets the selected profile actually needs — in Phase 1 it stays quiet about RunPod and MCP credentials. Use `--all` to see every phase.

```console
$ ./scripts/stack.sh doctor
==> Config
  ✓ stack.yaml schema 1  project=sovereign-ai-stack  env=demo
  ✓ target=docker  profile=phase-1
==> Tooling
  ✓ yq v4.53.3
  ✓ docker 29.6.2
  ✓ docker compose 5.3.1
  ✓ docker daemon reachable
==> Secrets  (.env, phases 1..1)
  ✓ LITELLM_MASTER_KEY set
  ✓ OPENAI_API_KEY set
  ...
```

See [Credentials](credentials.md) for the full inventory.

---

## Target 1 — Docker on a laptop

Everything except GPU serving runs locally in one compose stack.

```bash
./scripts/stack.sh up --target docker --profile phase-1
```

| Service | URL | Notes |
|---|---|---|
| LibreChat | <http://localhost:3080> | Chat UI, model picker |
| LiteLLM | <http://localhost:4000> | Unified gateway |
| Langfuse | <http://localhost:3000> | Observability UI |
| ClickHouse | `localhost:8123` | Langfuse trace store |
| MinIO | <http://localhost:9001> | Blob store backing Langfuse |

### First-time setup

1. Open Langfuse → create an org and project → copy the public and secret keys.
2. Paste them into `secrets/credentials.yaml`, then `./scripts/stack.sh secrets write`.
3. `./scripts/stack.sh up` again — LiteLLM restarts and picks up the callback keys.
4. Verify: `./scripts/stack.sh status`

```console
$ ./scripts/stack.sh status
==> Health  host=localhost
  ✓ litellm      200  http://localhost:4000/health/liveliness
  ✓ langfuse     200  http://localhost:3000/api/public/health
  ✓ librechat    200  http://localhost:3080/health
  ✓ clickhouse   200  http://localhost:8123/ping
```

Open Langfuse — you should see traces for `gpt-4o` and `claude-sonnet` in one project.

!!! tip "Health checks follow the profile"
    `status` only checks layers the active profile brought up. It won't report a missing vLLM pod in Phase 1.

---

## Target 2 — AWS EC2 with Terraform

Provisions a single EC2 instance (default `t3.xlarge`, gp3 volume), security groups, and an Elastic IP, then bootstraps the same compose stack via cloud-init.

```bash
./scripts/stack.sh up --target aws-ec2 \
  --tf-var key_name=<your-keypair> \
  --tf-var allowed_cidr=<your-ip>/32
```

Instance type, volume size, and region come from `targets.aws-ec2.vars` in `stack.yaml`; `--tf-var` overrides or adds. The host for `status` and `urls` is read from the `public_ip` Terraform output, so **no IP is ever hard-coded**.

!!! danger "Do not open to `0.0.0.0/0`"
    The security group restricts inbound to `allowed_cidr`. These ports are unauthenticated by default and the stack holds live provider API keys.

### Production hardening

- ALB + ACM certificate in front
- Postgres → RDS
- ClickHouse → ClickHouse Cloud
- Secrets → SSM Parameter Store

### Teardown

```bash
./scripts/stack.sh down --target aws-ec2
```

From Phase 3 on, RunPod pods are billed separately — stop them in the RunPod console.

---

## Phase 3 — vLLM on RunPod

Not required to run the stack today. See [Build-out phases](phases.md#phase-3-self-hosted-serving).

Deploy via RunPod's **vLLM Quick Deploy template** (recommended) or manually on any GPU pod:

```bash
# on the pod — 1× A40 / L40S is enough for a 7B model
pip install vllm
vllm serve Qwen/Qwen2.5-7B-Instruct --port 8000 --api-key ${VLLM_API_KEY}
```

Expose port 8000 through RunPod's HTTP proxy and record the endpoint — **note the `/v1` suffix**:

```
https://<pod-id>-8000.proxy.runpod.net/v1
```

Put it in `secrets/credentials.yaml` as `VLLM_API_BASE`, then:

```bash
./scripts/stack.sh secrets write
./scripts/stack.sh up --profile phase-3
```

!!! warning "Always set `--api-key`"
    The RunPod HTTP proxy is public by default. A pod without an API key is an open GPU on the internet.

---

## Client code

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

That is the whole point of the gateway: swapping `gpt-4o` for a self-hosted `qwen-7b` changes one string, and the trace still lands in the same Langfuse project with the same shape.

---

## Troubleshooting

??? question "`error: compose file not found: docker/docker-compose.yml`"
    The compose stack is Phase 1 work in progress. `stack.yaml`, `stack.sh`, and the rendered gateway configs are in place; `docker/docker-compose.yml` is not yet scaffolded.

??? question "`yq not found`"
    `brew install yq`. The script requires [mikefarah/yq](https://github.com/mikefarah/yq) v4 specifically and refuses other implementations — the Python `yq` has incompatible syntax.

??? question "A model appears in the picker but requests fail"
    Its API key is unset. `render` warns about this rather than silently dropping the model:

    ```
    ! model 'gpt-4o' selected but $OPENAI_API_KEY is not set — requests to it will fail
    ```

    Run `./scripts/stack.sh doctor` to see every gap at once.

??? question "Traces are not appearing in Langfuse"
    LiteLLM reads the Langfuse keys at startup. After adding them, restart the gateway — `./scripts/stack.sh up` does this. Confirm `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are both set with `doctor`.

??? question "`target 'k8s' is declared but not implemented yet`"
    Expected. `targets.k8s` is reserved in the schema with `enabled: false` so the shape is stable; the Helm profile is on the roadmap.
