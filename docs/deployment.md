# Deployment

`stack.yaml` declares multiple targets, but only the Docker target is
implemented. This page describes current operations and keeps future targets
clearly separated.

For first-time machine and credential preparation, start with
[Getting started](getting-started.md).

## Target status

| Target | Lifecycle | Status |
|---|---|---|
| `docker` | Docker Compose | **Runnable** |
| `aws-ec2` | Terraform → EC2 → Compose | Declared; `terraform/` not implemented |
| `k8s` | Helm | Planned and disabled |

## Docker

Start the current Phase 1 profile:

```bash
./scripts/stack.sh up --target docker --profile phase-1
./scripts/stack.sh status
```

Useful operations:

```bash
./scripts/stack.sh urls
./scripts/stack.sh logs
./scripts/stack.sh config
./scripts/stack.sh models
./scripts/stack.sh down
```

`status` checks only the active profile. `urls` prints endpoints without making
requests.

### Published ports

| Service | Default |
|---|---|
| Langfuse | `3000` |
| LibreChat | `3080` |
| LiteLLM | `4000` |
| ClickHouse HTTP | `8123` |
| MinIO console | `9001` |
| MinIO API | `9002` |

Ports can be remapped for one invocation:

```bash
LANGFUSE_PORT=3100 CLICKHOUSE_HTTP_PORT=8124 ./scripts/stack.sh up
```

Postgres, Redis, MongoDB, ClickHouse's native protocol, and the Langfuse worker
are not published to the host.

### Data and teardown

```bash
./scripts/stack.sh down          # stop containers, keep volumes
./scripts/stack.sh down --purge  # also delete volumes
```

`--purge` permanently removes local stack data. Use it only for a disposable
environment.

Service credentials initialized into a persistent database or object-store
volume do not rotate merely because `.env` changes. Rotate the account inside
the service or recreate disposable volumes.

## AWS EC2

The intended target is a single EC2 instance bootstrapped with the same Compose
stack. Its target metadata and credential fields exist in `stack.yaml`, but
there is no `terraform/` implementation yet. Consequently:

```bash
./scripts/stack.sh up --target aws-ec2
```

exits with an implementation error; it does not provision AWS resources.

The planned authentication paths are:

- IAM Identity Center through `AWS_PROFILE` (preferred)
- a scoped static access-key pair where SSO is unavailable

The planned target will also require a narrow inbound CIDR. Never expose a demo
stack holding provider keys through `0.0.0.0/0`.

## External vLLM serving

Phase 3 is planned and is not required for the current demo. The design treats
vLLM as an externally managed OpenAI-compatible endpoint rather than a local
Compose service. When implemented, it will require:

- a live `VLLM_API_BASE` ending in `/v1`
- a `VLLM_API_KEY`
- a running GPU endpoint, initially expected on RunPod

Do not expose a vLLM endpoint without authentication; a public unauthenticated
GPU endpoint can be used by anyone.

## Client endpoint

Every model is called through LiteLLM:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000",
    api_key="<LITELLM_MASTER_KEY>",
)

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Hello"}],
)
```

Changing provider or serving implementation changes the model alias and
gateway configuration, not the client protocol.

## Troubleshooting

??? question "`yq not found`"
    Install mikefarah/yq v4. Other programs named `yq` use incompatible
    syntax.

??? question "A model appears in the picker but requests fail"
    The catalog is rendered independently of provider-key liveness. Run
    `./scripts/stack.sh doctor` and verify the selected provider credential.

??? question "Traces are missing"
    LiteLLM reads Langfuse keys at startup. Validate the credentials, then run
    `./scripts/stack.sh up` again to reload them.

??? question "The AWS or Kubernetes target refuses to start"
    Expected in the current repository. Those targets are declarations of the
    intended interface, not completed deployment artifacts.
