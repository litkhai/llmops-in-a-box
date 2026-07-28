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
| `aws-ec2` | Terraform → EC2 → Compose | **Runnable** |
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

A single EC2 instance running the same Docker Compose stack as the local
target. Region: `ap-northeast-2`. Instance: `t3.xlarge`, 100 GiB gp3.

### Prerequisites

| Requirement | Check |
|---|---|
| AWS CLI v2 configured | `aws sts get-caller-identity` |
| EC2 key pair in `ap-northeast-2` | AWS console → EC2 → Key Pairs |
| Terraform ≥ 1.5 | `terraform version` |
| Phase 1 credentials set locally | `./scripts/stack.sh secrets status --phase 1` |

### 1. Push credentials to SSM

The EC2 instance reads Phase 1 credentials from SSM Parameter Store at boot.
Push them before provisioning:

```bash
./scripts/stack.sh secrets push --target aws-ec2
```

This writes every set Phase 1 credential as an SSM `SecureString` parameter
under `/sais/phase-1/`. The EC2 IAM role (provisioned by Terraform) grants
read access to that prefix only — no other AWS resources are reachable.

Verify:

```bash
aws ssm get-parameters-by-path \
  --region ap-northeast-2 \
  --path /sais/phase-1 \
  --query 'Parameters[*].Name'
```

### 2. Provision and bootstrap

```bash
./scripts/stack.sh up --target aws-ec2 \
    --tf-var key_name=<your-key-pair-name> \
    --tf-var allowed_cidr=<your-ip>/32
```

This runs `terraform apply`, then waits up to 5 minutes for the bootstrap
script to complete. The bootstrap script installs Docker, clones this
repository, pulls credentials from SSM, and starts the Phase 1 compose stack.

Get your public IP: `curl -s https://checkip.amazonaws.com`

!!! warning "Never use `0.0.0.0/0` for `allowed_cidr`"
    The stack holds live provider API keys. An open security group is a
    billing and data-exposure risk. Terraform's variable validation will
    reject `0.0.0.0/0` outright.

### 3. Verify

```bash
./scripts/stack.sh status --target aws-ec2
./scripts/stack.sh urls --target aws-ec2
```

If bootstrap is still running, inspect the log:

```bash
./scripts/stack.sh ssh --target aws-ec2
# on the instance:
sudo tail -f /var/log/bootstrap-ec2.log
```

### 4. Tear down

```bash
./scripts/stack.sh down --target aws-ec2
```

Runs `terraform destroy`. Removes the EC2 instance and security group. SSM
parameters are **not** deleted automatically — clean them up separately:

```bash
aws ssm delete-parameters \
  --region ap-northeast-2 \
  --names $(aws ssm get-parameters-by-path \
    --region ap-northeast-2 \
    --path /sais/phase-1 \
    --query 'Parameters[*].Name' \
    --output text)
```

### Credential rotation

Database credentials written into persistent volumes (Postgres, ClickHouse,
MinIO, MongoDB) do not rotate when SSM parameters change. After changing a
credential:

1. Update the SSM value: `./scripts/stack.sh secrets push --target aws-ec2`
2. Either recreate the affected service volume, or run `down --purge` and
   reprovision from scratch.

### Approximate cost

| Resource | On-demand, ap-northeast-2 |
|---|---|
| t3.xlarge | ~$120 / month |
| 100 GiB gp3 EBS | ~$8 / month |
| Data transfer | usage-dependent |

Stop or terminate the instance when not in use. This is a demo stack, not a
production service.

## External vLLM serving

Phase 3 is not built yet and is not required for the current demo. The design
treats vLLM as an externally managed OpenAI-compatible endpoint rather than a
local Compose service. When implemented, it will require:

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

??? question "The Kubernetes target refuses to start"
    Expected in the current repository. That target is a declaration of the
    intended interface, not a completed deployment artifact.
