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

Services are accessible via direct port (3000, 3080, 4000) or, when a domain
is configured, via HTTPS subdomains (`chat.<domain>`, `langfuse.<domain>`,
`litellm.<domain>`).

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

### 2. (Optional) Configure a custom domain

Skip this step for plain HTTP access via direct ports.

**a. Add DNS records.** In your DNS provider, create `A` records pointing each
subdomain at the EC2 instance's public IP:

| Subdomain | Points to |
|---|---|
| `chat.<your-domain>` | EC2 public IP |
| `langfuse.<your-domain>` | EC2 public IP |
| `litellm.<your-domain>` | EC2 public IP |
| `media.<your-domain>` | EC2 public IP |

**b. Set domain config interactively:**

```bash
./scripts/stack.sh secrets domain
```

This prompts for `DOMAIN_BASE` (e.g. `example.com`) and `DOMAIN_SSL_EMAIL`
(Let's Encrypt contact) and writes them to `.env`.

**c. Push the domain config to SSM:**

```bash
./scripts/stack.sh secrets push --target aws-ec2
```

The bootstrap script reads `DOMAIN_BASE` from SSM at first boot. If set, it
renders a `Caddyfile` and starts the Caddy reverse proxy automatically.
Caddy obtains a TLS certificate from Let's Encrypt without any manual steps.

**Certificate lifecycle:** Let's Encrypt certificates are valid for 90 days.
Caddy renews them automatically (typically at 30 days remaining). As long as
the instance is running and reachable on port 80/443, certificates stay current
indefinitely.

### 3. Provision and bootstrap

```bash
./scripts/stack.sh up --target aws-ec2 \
    --tf-var key_name=<your-key-pair-name>
```

This runs `terraform apply`, then waits up to 5 minutes for the bootstrap
script to complete. The bootstrap script:
1. Installs Docker, yq
2. Clones this repository
3. Pulls all credentials (including `DOMAIN_BASE`) from SSM
4. Starts the Phase 1 compose stack
5. If `DOMAIN_BASE` is set: renders `Caddyfile` and starts the Caddy proxy

### 4. Verify

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

### 5. Tear down

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

### Enabling HTTPS on a running instance

If the instance is already running and you want to add HTTPS:

```bash
# 1. Set domain config locally and push to SSM
./scripts/stack.sh secrets domain
./scripts/stack.sh secrets push --target aws-ec2

# 2. SSH into the instance and apply
./scripts/stack.sh ssh --target aws-ec2
```

On the instance:

```bash
cd /opt/llmops-in-a-box

# Pull latest code
git pull origin main

# Write DOMAIN_BASE and DOMAIN_SSL_EMAIL into .env
# (re-fetch from SSM, or set directly)
echo "DOMAIN_BASE=example.com" >> .env
echo "DOMAIN_SSL_EMAIL=you@example.com" >> .env

# Render Caddyfile and start proxy
./scripts/stack.sh render --target aws-ec2 --profile phase-1
docker compose --project-name sais --profile proxy -f docker/docker-compose.yml up -d
```

### Approximate cost

| Resource | On-demand, ap-northeast-2 |
|---|---|
| t3.xlarge | ~$120 / month |
| 100 GiB gp3 EBS | ~$8 / month |
| Data transfer | usage-dependent |

Stop or terminate the instance when not in use. This is a demo stack, not a
production service.

### Published ports (EC2)

| Service | Direct port | HTTPS subdomain (if domain configured) |
|---|---|---|
| LibreChat | `3080` | `chat.<domain>` |
| Langfuse | `3000` | `langfuse.<domain>` |
| LiteLLM | `4000` | `litellm.<domain>` |
| MinIO (images) | `9002` | `media.<domain>` |

Ports 80 and 443 are open to `0.0.0.0/0` for HTTPS. The remaining ports use
`allowed_cidr` (default `0.0.0.0/0`; each service has its own authentication).

## Phase 2 — MCP tool layer

Phase 2 adds the `mcp-clickhouse` service and wires it into the LiteLLM
gateway. Port 9100 is internal to the Docker network; no security group change
is needed for the aws-ec2 target.

### Prerequisites

Set Phase 2 credentials before starting:

```bash
./scripts/stack.sh secrets setup --phase 2
```

For the aws-ec2 target, push them to SSM:

```bash
./scripts/stack.sh secrets push --target aws-ec2
```

### Start Phase 2

```bash
./scripts/stack.sh render --profile phase-2
./scripts/stack.sh up --profile phase-2
./scripts/stack.sh status
```

`render --profile phase-2` generates `docker/litellm_config.yaml` with the
`mcp_servers` block pointing at `http://mcp-clickhouse:9100/sse`. The tools
layer starts under the `tools` compose profile alongside the gateway,
observability, and UI layers.

### Verify the MCP endpoint

```bash
curl http://localhost:4000/mcp
```

A healthy response lists the `clickhouse` server. On the aws-ec2 target,
use the LiteLLM HTTPS subdomain:

```bash
curl https://litellm.<domain>/mcp
```

### Published ports (Phase 2)

Port 9100 (`mcp-clickhouse`) is **not** published to the host. It is
accessible only within the Docker network by the LiteLLM container.

---

## GPU serving — vLLM on RunPod

Phase 4 is not built yet and is not required for the current demo. The design
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

??? question "Langfuse shows no traces — \"Event type not accepted\" in the ingestion response"
    Langfuse v4.0.0-rc.2 defaults `LANGFUSE_MIGRATION_V4_WRITE_MODE` to
    `events_only`, which rejects the SDK v2 `trace-create` events that LiteLLM
    sends. The fix is applied in `docker/docker-compose.yml`:
    `LANGFUSE_MIGRATION_V4_WRITE_MODE: "dual"`.

    Valid values are `"legacy"` | `"dual"` | `"events_only"` (not `"disabled"` or
    `"all"` — those fail Zod validation and crash the server on startup).

    - `"events_only"` — default for fresh v4 installs; rejects SDK v2 events.
    - `"legacy"` — accepts SDK v2 events but crashes the **worker** when
      `LANGFUSE_MIGRATION_V4_NATIVE_OTEL_BEHAVIOUR=direct` (the v4 fresh-install
      default) is also set.
    - `"dual"` — writes to both v3 and v4 paths; compatible with both the SDK v2
      client (LiteLLM) and the fresh-install worker config. This is the correct
      value for this stack.

    Verify the env var is live in the running container:

    ```bash
    docker compose --project-name sais exec langfuse-web env | grep MIGRATION
    # expected: LANGFUSE_MIGRATION_V4_WRITE_MODE=dual
    ```

    Test the ingestion endpoint (include a `timestamp` field — v4 requires it):

    ```bash
    curl -s -X POST http://localhost:3000/api/public/ingestion \
      -H "Content-Type: application/json" \
      -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
      -d '{"batch":[{"id":"t1","timestamp":"2026-01-01T00:00:00Z","type":"trace-create","body":{"id":"test","name":"test","timestamp":"2026-01-01T00:00:00Z"}}]}'
    ```

    A healthy response is `{"successes":[{"id":"t1","status":201}],"errors":[]}`.

    **Important:** `docker compose restart` does not apply env var changes from
    `docker-compose.yml`. Use `docker compose up -d --no-deps langfuse-web langfuse-worker`
    to recreate the containers and pick up the new value.

    Remove the override once LiteLLM upgrades its bundled Langfuse SDK from
    v2 to v3, which uses the new v4 ingestion path.

??? question "`No fallback model group found for original model_group=auto`"
    The language-routing callback rewrites `auto` to `gpt-4o` (English) or
    `claude-sonnet` (Korean/multilingual) before the request is dispatched.
    When that model then fails, LiteLLM looks up the fallback for the
    **original** model group (`auto`), not the rewritten one. Without an
    entry for `auto` in the fallback list, no recovery occurs.

    The fix is in `stack.yaml`: `auto` is listed under
    `layers.gateway.options.routing.fallbacks` with `claude-sonnet` as its
    target, and `scripts/stack.sh` includes `auto` when rendering the
    LiteLLM fallback table.

    If you see this error after editing `stack.yaml`, verify that `auto`
    appears in the `fallbacks` list, then re-render:

    ```bash
    ./scripts/stack.sh render
    ```

??? question "`mcp-clickhouse` container exits immediately after start"
    **Symptom:** The `mcp-clickhouse` container stops with an error about an
    unrecognised flag (`--transport sse not supported`).

    **Cause:** The `mcp-clickhouse` package version in use may not support
    `--transport sse` as a CLI flag. Use the `mcp-proxy` wrapper approach or
    pin to a version that supports SSE transport.

    **Fix:** Check the `docker/mcp/Dockerfile` entrypoint. If the package
    does not support `--transport sse`, install `mcp-proxy` and wrap the
    stdio server:

    ```dockerfile
    CMD ["mcp-proxy", "--port", "9100", "--", \
         "python", "-m", "mcp_clickhouse"]
    ```

    Then rebuild: `docker compose build mcp-clickhouse`.

??? question "LiteLLM `/mcp` endpoint returns 404"
    **Cause:** The stack was not rendered with `--profile phase-2`, so
    `mcp_servers` is absent from `docker/litellm_config.yaml`.

    **Fix:**

    ```bash
    ./scripts/stack.sh render --profile phase-2
    docker compose up -d --no-deps litellm
    ```

    Verify the block is present:

    ```bash
    grep -A5 mcp_servers docker/litellm_config.yaml
    ```

??? question "ClickHouse connection refused inside `mcp-clickhouse`"
    **Symptom:** The container starts but tool calls fail with a connection
    error. Container logs show `Connection refused` or `authentication failed`.

    **Cause:** `CLICKHOUSE_HOST`, `CLICKHOUSE_USER`, or
    `CLICKHOUSE_PASSWORD` is missing or incorrect, or `CLICKHOUSE_SECURE` is
    not set to `true` for ClickHouse Cloud.

    **Fix:** Verify the values in the running container:

    ```bash
    docker compose exec mcp-clickhouse env | grep CLICKHOUSE
    ```

    If any value is wrong, update credentials and restart:

    ```bash
    ./scripts/stack.sh secrets setup --phase 2
    ./scripts/stack.sh secrets write
    docker compose up -d --no-deps mcp-clickhouse
    ```

??? question "Image generation returns an error"
    The `UnifiedRouter` callback calls Cloudflare Workers AI directly. Verify
    that `CF_API_TOKEN` and `CF_ACCOUNT_ID` are present in the running container:

    ```bash
    docker compose exec litellm env | grep CF_
    ```

    If any variable is missing, set it with
    `./scripts/stack.sh secrets setup --phase 1`, then restart LiteLLM:

    ```bash
    ./scripts/stack.sh secrets write
    docker compose up -d --no-deps litellm
    ```

    See [Credentials — Image generation (free tier)](credentials.md#image-generation-free-tier)
    for token acquisition steps.
