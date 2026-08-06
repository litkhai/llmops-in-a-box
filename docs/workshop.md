# Workshop — Phase 1

This exercise starts with a prepared Docker machine and credential inventory.
If those are not ready, complete [Getting started](getting-started.md) first.

**Outcome:** OpenAI and/or Anthropic requests pass through LiteLLM and appear
in one Langfuse project with latency, token, cost, and failure data.

Phase 1 uses external model APIs. It is not an air-gapped exercise.

## 1. Start the stack

```bash
./scripts/stack.sh doctor
./scripts/stack.sh up
./scripts/stack.sh status
```

The first run pulls nine container images and can take several minutes.
Langfuse also runs database migrations before reporting healthy.

Expected endpoints:

| Service | URL | Purpose |
|---|---|---|
| LibreChat | <http://localhost:3080> | Chat UI and model picker |
| LiteLLM | <http://localhost:4000> | OpenAI-compatible gateway |
| Langfuse | <http://localhost:3000> | Traces and cost |
| ClickHouse | <http://localhost:8123/ping> | Langfuse trace store |
| MinIO | <http://localhost:9001> | Langfuse blob-store console |

Nine containers implement three visible layers. Langfuse requires a web
service, worker, ClickHouse, Postgres, Redis, and MinIO; LibreChat also requires
MongoDB.

## 2. Log in

| Service | Account |
|---|---|
| LiteLLM | `UI_USERNAME` / `UI_PASSWORD` |
| Langfuse | `LANGFUSE_INIT_USER_EMAIL` / `LANGFUSE_INIT_USER_PASSWORD` |
| LibreChat | Register on first visit |
| MinIO | `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` |

To retrieve one stored login without listing secrets, reopen
`secrets setup`, select its technology and credential, then use `c` to copy.
Use `r` only when terminal scrollback exposure is acceptable.

Langfuse headless initialization creates the initial organization, project,
user, and project keys on first boot. No copy-and-restart cycle is required.

## 3. Send a traced request

Install the OpenAI Python package if your environment does not already have it,
then use the LiteLLM endpoint:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000",
    api_key="<LITELLM_MASTER_KEY>",
)

response = client.chat.completions.create(
    model="gpt-4o",
    messages=[
        {"role": "user", "content": "Explain ClickHouse in one sentence."}
    ],
)
print(response.choices[0].message.content)
```

Use `claude-sonnet` instead if only Anthropic is configured.

**Checkpoint:** open Langfuse → **Tracing**. The request should contain the
prompt, completion, latency, token counts, and computed cost. The client code
contains no Langfuse integration; LiteLLM emitted the trace.

## 4. Compare providers

If both provider keys are configured:

```python
for model in ["gpt-4o", "claude-sonnet"]:
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "user", "content": "Explain ClickHouse in one sentence."}
        ],
    )
    print(model, "→", response.choices[0].message.content)
```

**Checkpoint:** both traces appear in the same Langfuse project with their own
latency, token, and cost data. Only the model alias changed in the client.

## 5. Generate an image

The chat model picker shows only `auto`. Image generation is triggered directly from chat — no separate UI required. Type a message containing image-intent keywords and the `UnifiedRouter` callback detects the intent automatically:

- Korean: `파란색 배경에 고양이 그림 그려줘`
- English: `generate an image of a mountain landscape at sunrise`

The callback calls Cloudflare Workers AI (FLUX.1-schnell) directly. The generated image is stored in MinIO and the streaming hook replaces the 1-token LLM response with a markdown image link. LibreChat renders the image inline in the chat.

**Checkpoint:** open Langfuse → **Tracing**. A trace should appear for the 1-token LLM placeholder call made while the image generates in the background. The `model` field shows `claude-sonnet` (the placeholder call). The chat response contains a markdown image rendered inline by LibreChat.

If neither token is configured, image generation requests return an error;
the chat path is unaffected.

## 6. Exercise the failure path

```python
client.chat.completions.create(
    model="gpt-4o-typo",
    messages=[{"role": "user", "content": "hi"}],
)
```

Check whether the rejected call appears as a failed trace. Rehearse this before
a live presentation: provider and gateway versions can differ in how early
they reject an invalid alias.

## 7. Stop the stack

```bash
./scripts/stack.sh down          # keep volumes
./scripts/stack.sh down --purge  # delete disposable demo data
```

`--purge` is destructive. It is appropriate for resetting a demo, not for
data you need to retain.

Changing Postgres, ClickHouse, or MinIO passwords in `.env` does not update
accounts already stored in persistent volumes. Rotate them inside the service
or recreate disposable volumes. Preserve `LANGFUSE_ENCRYPTION_KEY`; losing it
can make stored encrypted data unreadable.

## Troubleshooting


??? failure "A published port is already in use"
    Override it for the process:

    ```bash
    LANGFUSE_PORT=3100 CLICKHOUSE_HTTP_PORT=8124 ./scripts/stack.sh up
    ```

??? failure "A service remains unhealthy"
    First boot may take a minute or two. If it persists:

    ```bash
    ./scripts/stack.sh logs
    ```

??? failure "A model is visible but requests fail"
    Its provider key may be missing or invalid. Run:

    ```bash
    ./scripts/stack.sh secrets validate --phase 1
    ./scripts/stack.sh doctor
    ```

??? failure "Requests succeed but traces do not appear"
    Confirm the Langfuse public and secret keys are present with `doctor`, then
    run `./scripts/stack.sh up` again so LiteLLM reloads them.

Next: use the [Demo flow](demo-flow.md), change the model catalog in
[Configuration](configuration.md), or continue to the Phase 2 workshop below.

---

# Workshop — Phase 2

Phase 2 adds the `mcp-clickhouse` service and wires MCP tools into the LiteLLM
gateway.

**Target:** `aws-ec2`. Phase 2 requires the EC2 deployment target. If you are
still running locally, follow
[Getting started — Moving to Phase 2](getting-started.md#moving-to-phase-2)
first to provision the EC2 instance.

**Prerequisites:** Phase 1 running on EC2; ClickHouse Cloud credentials
configured (see [Credentials — MCP](credentials.md#mcp-clickhouse-cloud)).

**Outcome:** Tool calls from any client reach ClickHouse Cloud through the
gateway and appear as traces in Langfuse.

## 1. Configure Phase 2 credentials

```bash
./scripts/stack.sh secrets setup --phase 2
./scripts/stack.sh secrets push --target aws-ec2
```

Enter `CLICKHOUSE_CLOUD_HOST`, `CLICKHOUSE_CLOUD_USER`, and
`CLICKHOUSE_CLOUD_PASSWORD` when prompted. Use a read-only database user.

## 2. Render and start Phase 2

```bash
./scripts/stack.sh render --profile phase-2 --target aws-ec2
./scripts/stack.sh up --profile phase-2 --target aws-ec2
./scripts/stack.sh status --target aws-ec2
```

This renders `mcp_servers` into `docker/litellm_config.yaml` and starts the
`mcp-clickhouse` container alongside the existing Phase 1 services.

## 3. Verify the tools endpoint

```bash
curl https://litellm.<domain>/mcp
```

The response should list the `clickhouse` server.

## 4. Send a tool-calling request

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm.<domain>",
    api_key="<LITELLM_MASTER_KEY>",
)

response = client.chat.completions.create(
    model="claude-sonnet",
    messages=[
        {"role": "user", "content": "List the tables available in ClickHouse."}
    ],
)
print(response.choices[0].message.content)
```

**Checkpoint:** open Langfuse → **Tracing**. The trace should contain both the
model call and the tool call (arguments, result, latency). No client-side
tool configuration was needed.

## 5. Troubleshooting Phase 2

??? failure "`/mcp` returns 404"
    Render with `--profile phase-2` and restart LiteLLM. See
    [Deployment troubleshooting](deployment.md#troubleshooting) for details.

??? failure "`mcp-clickhouse` container is not healthy"
    Check credentials and transport support. See
    [Deployment troubleshooting](deployment.md#troubleshooting) for details.
