# Getting started

Prepare the deployment target and credentials here. Once both are ready, the
[Phase 1 workshop](workshop.md) is the same regardless of where the stack
eventually runs.

## 1. Choose a target

| Target | Scope | Status |
|---|---|---|
| `docker` | Phase 1 only — local development and iterating on the gateway | **Runnable** |
| `aws-ec2` | Phases 1 – 3 — primary demo and shared deployment target | **Running** |
| `k8s` | Future production deployment | Planned |

**Phase 1** (`--target docker`) is the right starting point. It runs the full
gateway, observability, and UI stack on your laptop using Docker Compose and
external provider APIs. No GPU, no EC2, no cloud account required.

**Phase 2 and above require `--target aws-ec2`.** The reasons are practical:

- ClickHouse Cloud MCP (Phase 2) requires outbound internet access, which EC2
  already has and a secured laptop may not.
- RunPod GPU serving (Phase 3) is an external service regardless of where the
  gateway lives; running the gateway on EC2 keeps latency predictable and avoids
  NAT traversal.
- The shared demo needs a stable address and HTTPS, which the EC2 target provides
  through Caddy.

The Phase 1 workshop below applies to both targets. Start locally if you want
to iterate quickly; provision EC2 when you are ready for Phase 2 or a shared
demo.

## 2. Prepare Docker

Requirements:

- Docker 24+ with Compose v2
- [mikefarah/yq](https://github.com/mikefarah/yq) v4
- about 5 GiB of free Docker memory; 8 GiB works, 12 GiB is comfortable
- at least one OpenAI or Anthropic API key

On macOS:

```bash
brew install yq
docker info --format 'CPUs={{.NCPU}}  Memory={{.MemTotal}}'
```

The stack publishes ports `3000`, `3080`, `4000`, `8080`, `9001`, and `9002`.
If one is occupied, either stop its owner or override the corresponding port
when starting the stack.

## 3. Configure credentials

Initialize the private inventory and open the Phase 1 menu:

```bash
./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1
```

Use the main menu in this order:

1. `d` — set shared demo login defaults: ID, email, and password.
2. Open **Model providers** and add at least one provider API key.
3. `g` — generate missing internal keys, salts, and service passwords.
4. `w` — validate the inventory and write `.env`.
5. `q` — finish.

The shared login is only a local-demo convenience. It is applied to compatible
service accounts, not to provider keys, gateway keys, JWTs, salts, or
encryption keys. Use unique service passwords outside a disposable demo.

`secrets/credentials.yaml` is the private source of truth. `.env` is generated
and overwritten by `secrets write`; do not edit it manually.

For the complete inventory, AWS authentication choices, validation behavior,
and leak response, see [Credentials](credentials.md).

## 4. Run the preflight

```bash
./scripts/stack.sh secrets status --phase 1
./scripts/stack.sh secrets validate --phase 1
./scripts/stack.sh doctor
```

`doctor` checks only the selected profile by default, so it does not require
future-phase credentials. A missing optional provider key is acceptable if the
other Phase 1 provider is configured.

## 5. Continue to the workshop

The machine and credentials are now ready:

```bash
./scripts/stack.sh up
./scripts/stack.sh status
```

Continue with the [Phase 1 workshop](workshop.md) to send a request, inspect
its trace, compare providers, and tear the stack down.

## Moving to Phase 2

When you are ready for Phase 2 (MCP tool layer), switch to the EC2 target.
You will need Terraform ≥ 1.5, an AWS account with EC2 and SSM access, and an
EC2 key pair in `ap-northeast-2`.

```bash
# Set Phase 2 credentials
./scripts/stack.sh secrets setup --phase 2

# A domain is required on EC2 — the security group publishes 80/443 only
./scripts/stack.sh secrets domain

# Push all credentials to SSM
./scripts/stack.sh secrets push --target aws-ec2

# Provision and start on EC2
./scripts/stack.sh up --target aws-ec2 --tf-var key_name=<your-key-pair>
```

On EC2 the services live at `https://chat.<domain>`, `https://langfuse.<domain>`,
and `https://litellm.<domain>` — not at `<ip>:<port>`. SSH is closed by default;
open it per session when you need it.

See [Deployment — AWS EC2](deployment.md#aws-ec2) for the full guide, including
optional HTTPS setup with a custom domain.

## Moving to Phase 3

Phase 3 adds `qwen-7b` on a RunPod Serverless endpoint. Create the endpoint in
the RunPod console first (vLLM worker template, `Qwen/Qwen2.5-7B-Instruct`), then:

```bash
./scripts/stack.sh secrets setup --phase 3     # VLLM_API_BASE, VLLM_API_KEY
./scripts/stack.sh secrets push --target aws-ec2
./scripts/stack.sh up --profile phase-3 --target aws-ec2
```

Language routing starts sending English and CJK traffic to `qwen-7b` as soon as
`VLLM_API_BASE` is set. See
[Deployment — Phase 3](deployment.md#phase-3-gpu-serving-on-runpod).
