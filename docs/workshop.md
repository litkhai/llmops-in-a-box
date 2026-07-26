# Workshop — Phase 1, end to end

A guided run from an empty machine to a traced request. Roughly **30 minutes**, most of it spent pulling images.

**What you have at the end:** one Langfuse project showing the same prompt answered by OpenAI and Anthropic, with per-model cost, latency and token counts side by side — and nothing instrumented in the application to make that happen. That single screen is the whole argument of [Phase 1](phases.md#phase-1-frontier-models).

Every step has a **checkpoint**. If one does not match, skip to [When it goes wrong](#when-it-goes-wrong).

!!! tip "Two things worth knowing before you start"
    - It costs a few cents of API spend. Nothing else.
    - You need **one** provider key, not both. The comparison is better with two, but the stack runs on either.

---

## Step 0 — Check the machine

Two things sink this before it starts: not enough memory in the Docker VM, and ports already in use.

```bash
docker info --format 'CPUs={{.NCPU}}  Memory={{.MemTotal}}'
```

The stack measures **4.7 GiB across nine containers** once warm. Docker Desktop's default allocation is often 8 GB, which works but leaves little room. If you have the host RAM, 12 GB is comfortable — *Settings → Resources → Memory*.

Then check the ports it wants:

```bash
for p in 3000 3080 4000 8123 9001 9002; do
  lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && echo "$p BUSY" || echo "$p free"
done
```

**Checkpoint:** six `free`. If not, either stop what is holding them or remap — every published port is overridable:

```bash
LANGFUSE_PORT=3100 LITELLM_PORT=4001 ./scripts/stack.sh up
```

!!! note "Only six ports are published, deliberately"
    Postgres, Redis, ClickHouse's native protocol and the Langfuse worker are reachable inside the compose network and **not** exposed to the host. They are the ports most likely to already be in use on a developer machine, and nothing outside the stack needs them. Run `docker compose -p sais exec postgres sh -c 'psql -U "$POSTGRES_USER"'` when you want a shell.

---

## Step 1 — Credentials

```bash
brew install yq            # mikefarah v4 — the script refuses other builds

./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1
```

The setup hub shows Phase 1 credentials grouped by technology. Work through it
in this order:

1. Press `d` for **Set default credentials**. It asks for a default ID, email,
   and password, then maps each to the technologies that use that login shape:
   LiteLLM receives the ID and Langfuse receives the email.
2. Open **Model providers** and enter at least one of `OPENAI_API_KEY` or
   `ANTHROPIC_API_KEY`. External values use hidden input and are validated
   before storage.
3. Press `g` to generate every remaining internal key, salt, and encryption
   value. Existing values are preserved.
4. Press `w` to validate the inventory and atomically write `.env` with mode
   `600`, then `q` to finish.

All values land in the gitignored `secrets/credentials.yaml` at mode `600`.
They stay hidden unless you explicitly select a configured item and choose `c`
to copy it or `r` to reveal it after a terminal-scrollback warning.

Where to obtain provider keys, and the gotchas for each, is in
[Credentials](credentials.md#kind-2-a-provider-console-you-need-an-account-possibly-a-payment-method).

!!! warning "Shared defaults are for the local demo"
    One password across local services is convenient, but one leak then reaches
    several services. Use unique service passwords in production. Apply default
    credentials before the first startup; changing `.env` later does not rotate
    accounts already stored inside persistent volumes.

```bash
./scripts/stack.sh doctor
```

**Checkpoint:** `doctor` exits 0 and the secrets section is green apart from keys you chose to skip.

```console
==> Secrets  (.env, phases 1..1)
  ✓ LITELLM_MASTER_KEY set
  ✓ LANGFUSE_PUBLIC_KEY set
  ✓ LANGFUSE_ENCRYPTION_KEY set
  ✓ REDIS_AUTH set
  ...
```

!!! warning "Do not edit `.env` by hand"
    It is generated from `secrets/credentials.yaml` and overwritten on every `secrets write`. Edit the source, then re-run write.

---

## Step 2 — Bring it up

```bash
./scripts/stack.sh up
```

First run pulls about nine images, so expect several minutes. Afterwards it is seconds.

```console
==> Bringing up  docker  profile=phase-1
  ✓ rendered docker/litellm_config.yaml
  ✓ rendered docker/librechat.yaml

endpoints
  litellm        http://localhost:4000
  langfuse       http://localhost:3000
  librechat      http://localhost:3080
```

**Checkpoint:**

```bash
./scripts/stack.sh status
```

```console
==> Health  host=localhost
  ✓ litellm      200  http://localhost:4000/health/liveliness
  ✓ langfuse     200  http://localhost:3000/api/public/health
  ✓ librechat    200  http://localhost:3080/health
  ✓ clickhouse   200  http://localhost:8123/ping
  ✓ langfuse-minio 200  http://localhost:9002/minio/health/live
```

Langfuse takes the longest — first boot runs Postgres and ClickHouse migrations. Give it a minute before deciding something is wrong.

### What you just started

Three layers, **nine containers**. The gap surprises people, so it is worth seeing plainly:

| Service | Host port | Role |
|---|---|---|
| LiteLLM | 4000 | the gateway — one OpenAI-compatible endpoint |
| Langfuse web | 3000 | traces, cost, the UI you demo from |
| Langfuse worker | — | ingestion and batch jobs |
| LibreChat | 3080 | chat UI, model picker |
| ClickHouse | 8123 | Langfuse's OLAP trace store |
| MinIO | 9001 · 9002 | Langfuse's blob store |
| Postgres | — | Langfuse metadata; also LiteLLM's own database |
| Redis | — | Langfuse queue and cache |
| MongoDB | — | LibreChat's database |

Only three of those are layers you chose. **Six are Langfuse's and LibreChat's own requirements** — Langfuse v4 is two services plus four backends, all mandatory, and LibreChat needs MongoDB. See [Background](background.md#observability-langfuse) for why that trade was accepted.

### Log in

| | URL | Account |
|---|---|---|
| LiteLLM | <http://localhost:4000/ui> | `UI_USERNAME` / `UI_PASSWORD` — ID-based login |
| Langfuse | <http://localhost:3000> | `LANGFUSE_INIT_USER_EMAIL` / `_PASSWORD` — email-based login |
| LibreChat | <http://localhost:3080> | register on first visit |
| MinIO | <http://localhost:9001> | `MINIO_ROOT_USER` / `_PASSWORD` |

Langfuse should already have an organisation, a project **and** the API key pair — created on first boot from `LANGFUSE_INIT_*` rather than clicked through the UI. That is what stops the gateway from starting before the keys exist and tracing nothing. See [Credentials](credentials.md#kind-3-langfuse-keys-initialized-with-the-demo).

To retrieve a configured login without printing every secret, re-open
`secrets setup`, select that technology and credential, then use `c` to copy
the value. `r` is available when terminal scrollback exposure is acceptable.

---

## Step 3 — Your first traced request

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000", api_key="<LITELLM_MASTER_KEY>")

r = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Explain ClickHouse in one sentence."}],
)
print(r.choices[0].message.content)
```

**Checkpoint:** open Langfuse → **Tracing**. One trace, with the full prompt and completion, latency, token counts and a **computed cost**.

Nothing in that snippet mentions Langfuse. The trace exists because the gateway emitted it, which is the point being made.

---

## Step 4 — The comparison that is the point

```python
for m in ["gpt-4o", "claude-sonnet"]:
    r = client.chat.completions.create(
        model=m, messages=[{"role": "user", "content": "Explain ClickHouse in one sentence."}]
    )
    print(m, "→", r.choices[0].message.content[:80])
```

One string changed. Two providers with different wire formats, one SDK, one endpoint, one auth token.

**Checkpoint:** both traces in the **same** Langfuse project, with different per-model costs. Group by model and you have the cost comparison that makes self-hosted-versus-API decidable later, in [Phase 3](phases.md#phase-3-self-hosted-serving), rather than theoretical.

---

## Step 5 — Break it on purpose

A demo that only ever shows success cannot answer *"what happens when it fails?"* — and that is always asked.

```python
client.chat.completions.create(model="gpt-4o-typo", messages=[{"role": "user", "content": "hi"}])
```

**Checkpoint:** a **failed** trace in Langfuse, not an absence of one. `stack.yaml` registers Langfuse on the gateway's failure callback as well as success, which most setups skip — and skipping it means you learn about failures from users.

Rehearse this before any live demo. [Demo flow](demo-flow.md) builds the ten-minute version around it.

---

## Step 6 — Tear down

```bash
./scripts/stack.sh down             # stop, keep data
./scripts/stack.sh down --purge     # stop and drop volumes
```

!!! danger "Rotating a database password means purging the volume"
    Postgres, ClickHouse and MinIO write their password into the data directory at **first initialisation**. Changing `POSTGRES_PASSWORD` later and re-running `secrets write` gives you a stack that authenticates with the new value against a database still holding the old one, and it simply fails to connect.

    Rotate those three with `down --purge`, then `up`. On a demo stack that costs nothing; know it before you try it on something you care about.

    `LANGFUSE_ENCRYPTION_KEY` is worse: it encrypts stored credentials inside Langfuse, so losing it makes existing rows unreadable. Back it up before you rotate anything.

---

## When it goes wrong

??? failure "`Bind for 127.0.0.1:3000 failed: port is already allocated`"
    Something else on the machine holds the port — often another Langfuse, or a local Postgres or Redis.

    Every published port is overridable:

    ```bash
    LANGFUSE_PORT=3100 CLICKHOUSE_HTTP_PORT=8124 ./scripts/stack.sh up
    ```

    `MINIO_API_PORT` also drives the browser-facing media URL, so remapping it stays consistent automatically.

??? failure "A container sits at `unhealthy` but the URL works in your browser"
    Give it longer before concluding anything — Langfuse runs Postgres and ClickHouse migrations on first boot and can take a minute or two to report healthy.

    If it persists:

    ```bash
    docker compose -p sais logs <service> --tail 50
    ```

??? failure "Traces do not appear, but nothing looks broken"
    LiteLLM reads the Langfuse keys **at startup**. If the gateway booted before they existed, it runs fine and traces nothing.

    Headless initialization is what avoids this — the keys are chosen up front rather than fetched from a running Langfuse. Confirm with `doctor` that `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are set, then `./scripts/stack.sh up` to restart the gateway.

??? failure "A model is in the picker but every request to it fails"
    Its provider key is unset. `render` and `doctor` both warn rather than silently dropping the model:

    ```
    ! model 'gpt-4o' selected but $OPENAI_API_KEY is not set — requests to it will fail
    ```

    A missing provider key deliberately does not block startup — the rest of the stack still comes up.

---

## Where to go next

| | |
|---|---|
| Present this to someone | [Demo flow](demo-flow.md) — the ten-minute version with talking points |
| Understand the choices | [Background](background.md) — why a gateway, what was rejected, the glossary |
| See what comes after | [Build-out phases](phases.md) — tools, self-hosting, storage, recipes |
| Change what runs | [Configuration](configuration.md) — adding a model, layers, profiles |
