# Troubleshooting

Collected fixes for issues encountered during development and deployment of the
Phase 1 stack.

---

## Terraform / AWS provisioning

??? failure "`terraform apply` fails: apostrophe in security group description"
    **Symptom:**
    ```
    Error: "description" doesn't comply with restrictions
    ("^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$")
    ```

    **Cause:** AWS security group descriptions do not allow apostrophes. Any
    description containing a `'` character (e.g. `"Let's Encrypt"`) will fail
    AWS validation.

    **Fix:** Remove apostrophes from all `description` fields in `sg.tf`, then
    re-run `terraform apply`.

??? failure "AWS session token invalid when passed inline with line breaks"
    **Symptom:**
    ```
    api error InvalidClientTokenId: The security token included in the request is invalid
    ```

    **Cause:** Pasting a multi-line `terraform apply` command in the terminal
    (with environment variables inlined) can split the `AWS_SESSION_TOKEN` value
    across shell lines, embedding newlines into the header value.

    **Fix:** `export` each variable separately first, then run `terraform apply`
    on its own line:

    ```bash
    export AWS_ACCESS_KEY_ID=...
    export AWS_SECRET_ACCESS_KEY=...
    export AWS_SESSION_TOKEN=...

    terraform apply
    ```

??? failure "EC2 public IP changes after `terraform apply`"
    **Symptom:** The Terraform output shows a new `public_ip` after a re-apply
    (e.g., when `user_data` changes). Services were reachable before but now
    return certificate errors or fail to connect.

    **Cause:** EC2 instances with dynamic (non-Elastic IP) addresses are
    assigned a new public IP when stopped and started. Any `user_data` change
    forces an instance replacement, which triggers this.

    **Fix:**

    1. Note the new `public_ip` from `terraform output`.
    2. Update all four DNS `A` records (`chat`, `langfuse`, `litellm`, `media`)
       to the new IP.
    3. Wait for DNS propagation, then restart Caddy so it re-issues TLS
       certificates against the new IP:
       ```bash
       docker restart sais-caddy-1
       ```

??? failure "Caddy TLS certificate fails after an IP change"
    **Symptom:**
    ```
    challenge failed — <ip>: Timeout during connect (likely firewall problem)
    ```

    **Cause:** Let's Encrypt's validation servers still resolve the domain to
    the old IP because DNS has not yet propagated.

    **Fix:** Wait for DNS propagation (usually a few minutes for TTL-1 records,
    up to the TTL otherwise), then restart Caddy — it retries ACME automatically:

    ```bash
    docker restart sais-caddy-1
    ```

    Do not restart repeatedly before DNS has propagated; Let's Encrypt rate-limits
    failed certificate requests.

---

## LiteLLM callback configuration

??? failure "Custom callback not loading — `UnifiedRouter` never runs"
    **Symptom:** LiteLLM startup log shows:
    ```
    Initialized Success Callbacks - ['langfuse']
    ```
    The `UnifiedRouter` callback is never invoked.

    **Cause:** LiteLLM proxy silently ignores the `custom_callbacks` key in
    `litellm_settings`. Only the `callbacks` key is honoured.

    **Fix:** Use `callbacks: [callbacks.language_router]` (a
    `module.attribute` path), not `custom_callbacks`:

    ```yaml title="docker/litellm_config.yaml"
    litellm_settings:
      callbacks: [callbacks.language_router]
    ```

    The callback module is `callbacks.py` (mounted at `/app/callbacks.py`) and
    `language_router` is the `UnifiedRouter()` instance at module level.

??? failure "`async_pre_call_hook` never called for LibreChat requests"
    **Symptom:** The hook is defined and the module loads successfully, but the
    hook body never executes for requests sent from LibreChat.

    **Cause:** LibreChat sends requests asynchronously. LiteLLM sets
    `call_type = 'acompletion'`, not `'completion'`. A guard that checks only
    for `'completion'` will skip all LibreChat traffic.

    **Fix:** Check for both call types:

    ```python
    if call_type not in ("completion", "acompletion"):
        return data
    ```

---

## Image generation

??? failure "Image generation via `/v1/images/generations` returns `{\"data\":[]}`"
    **Symptom:** The LiteLLM image generation endpoint returns an empty `data`
    array in ~17 ms. No image is produced and no error is logged.

    **Cause:** LiteLLM proxy does not natively support Cloudflare Workers AI as
    an image generation backend. It returns an empty response without error.

    **Fix:** Call the provider APIs directly using `httpx` inside the callback.
    Do not route image generation through LiteLLM's `/v1/images/generations`
    endpoint. The `UnifiedRouter` callback handles this in the
    `async_pre_call_hook` by dispatching an `asyncio.Task` that calls the
    providers directly.

??? failure "LibreChat shows a blank response for image generation"
    **Symptom:** The API returns the correct `![generated image](https://...)`
    markdown, but LibreChat displays an empty message bubble.

    **Cause:** Setting `data["stream"] = False` in `async_pre_call_hook` causes
    LiteLLM to return a single non-streaming JSON response. LibreChat's stream
    handler expects SSE events and silently discards the JSON body.

    **Fix:** Do not force `stream=False` in `async_pre_call_hook`. Instead,
    implement `async_post_call_streaming_iterator_hook` to drain the 1-token
    streaming response and yield new SSE chunks containing the image markdown.
    The stream stays open from LibreChat's perspective; only the content changes.

??? failure "LibreChat does not render inline `data:` URI images"
    **Symptom:** A response containing `![img](data:image/jpeg;base64,...)`
    appears as a blank image placeholder in LibreChat.

    **Cause:** Browser Content Security Policy blocks inline `data:` images
    embedded in markdown rendered inside LibreChat.

    **Fix:** Upload the generated image to MinIO and return a public `https://`
    URL instead (e.g. `https://media.<domain>/images/generated/<id>.jpg`). The
    `UnifiedRouter` callback stores the image in MinIO before injecting the
    markdown link.

---

## MCP tool layer (Phase 2)

??? failure "`mcp-clickhouse` container exits immediately — `--transport sse` not supported"
    **Symptom:** The container stops at startup. Logs show an error about an
    unrecognised flag or unsupported transport.

    **Cause:** The installed `mcp-clickhouse` package version does not accept
    `--transport sse` as a CLI argument.

    **Fix:** Use the `mcp-proxy` wrapper in `docker/mcp/Dockerfile` to expose
    the stdio-only server over SSE:

    ```dockerfile
    CMD ["mcp-proxy", "--port", "9100", "--", \
         "python", "-m", "mcp_clickhouse"]
    ```

    Rebuild the image:

    ```bash
    docker compose build mcp-clickhouse
    docker compose up -d --no-deps mcp-clickhouse
    ```

??? failure "LiteLLM `/mcp` endpoint returns 404"
    **Symptom:** `curl http://localhost:4000/mcp` returns a 404 or empty
    response.

    **Cause:** The stack was rendered without `--profile phase-2`, so the
    `mcp_servers` block is absent from `docker/litellm_config.yaml`.

    **Fix:**

    ```bash
    ./scripts/stack.sh render --profile phase-2
    docker compose up -d --no-deps litellm
    ```

    Confirm the block is present:

    ```bash
    grep -A5 mcp_servers docker/litellm_config.yaml
    ```

??? failure "Tool calls fail — ClickHouse connection refused or authentication error"
    **Symptom:** The `/mcp` endpoint responds but tool calls return a
    connection or authentication error. Container logs show `Connection refused`
    or `Code: 516. DB::Exception: Authentication failed`.

    **Cause:** `CLICKHOUSE_HOST`, `CLICKHOUSE_USER`, or `CLICKHOUSE_PASSWORD`
    is wrong, or `CLICKHOUSE_SECURE` is not set to `true` (required for
    ClickHouse Cloud).

    **Fix:** Check the live environment variables:

    ```bash
    docker compose exec mcp-clickhouse env | grep CLICKHOUSE
    ```

    Update credentials and restart:

    ```bash
    ./scripts/stack.sh secrets setup --phase 2
    ./scripts/stack.sh secrets write
    docker compose up -d --no-deps mcp-clickhouse
    ```

---

## Langfuse traces

??? failure "Traces missing — \"Event type not accepted\" in ingestion response"
    See [Deployment — Troubleshooting](deployment.md#troubleshooting) for the
    full fix. Short version: set `LANGFUSE_MIGRATION_V4_WRITE_MODE=dual` in
    `docker-compose.yml` for the `langfuse-web` and `langfuse-worker` services,
    then recreate the containers:

    ```bash
    docker compose up -d --no-deps langfuse-web langfuse-worker
    ```

??? failure "`No fallback model group found for original model_group=auto`"
    See [Deployment — Troubleshooting](deployment.md#troubleshooting) for the
    full fix. Short version: add `auto` to the fallback list in `stack.yaml`
    under `layers.gateway.options.routing.fallbacks`, then re-render.
