# Credentials

Every API key the stack touches — OpenAI, Anthropic, RunPod, AWS, ClickHouse Cloud, Langfuse, MinIO — is inventoried in **one** file.

```mermaid
flowchart LR
    C["<b>secrets/credentials.yaml</b><br/><small>you edit this</small>"]
    E["<b>.env</b><br/><small>generated · mode 600</small>"]
    D["docker compose"]
    T["terraform"]

    C -->|"secrets write"| E
    E --> D
    E --> T

    classDef src fill:#0969da,stroke:#0969da,color:#fff
    classDef gen fill:#bf8700,stroke:#bf8700,color:#fff
    class C src
    class E gen
```

`secrets/credentials.yaml` is the only credential file you hand-edit. `.env` is derived from it and **gets overwritten** — never edit it directly.

---

## Setup

```bash
cp secrets/credentials.example.yaml secrets/credentials.yaml
./scripts/stack.sh secrets gen            # values for the self-generated keys
$EDITOR secrets/credentials.yaml          # paste those + your provider keys
./scripts/stack.sh secrets write          # generate .env (mode 600)
./scripts/stack.sh doctor                 # verify the stack sees them
```

`secrets gen` prints a fresh value for every credential that declares a `generate:` command:

```console
$ ./scripts/stack.sh secrets gen
==> Suggested values for self-generated credentials

  LITELLM_MASTER_KEY                 sk-f0476d619643e60b4e415c8b09320937fc0b315ccbd803a8
  LITELLM_SALT_KEY                   8e876ba991f91b74a465c93587a499774294888d30227840079b7798bc65af35
  NEXTAUTH_SECRET                    kRHoSMTAbV0rJ4vVb+dY80QVuSovpTm3TWSPE5HH4BQ=
  CLICKHOUSE_PASSWORD                8cf628e750a627956d67a9df30c2c41b
```

---

## Where each credential comes from

Twenty-odd credentials sounds worse than it is, because **you only have to go and fetch about a third of them**. Sorting them by *where a value comes from* is the thing that makes this tractable — and it is also what the automation below is built on.

Each entry's `console:` field in `secrets/credentials.yaml` is the authoritative pointer; this is the map.

### Kind 1 — self-generated (no browser, no account)

These are passwords for services this stack runs itself. Nobody issues them to you; you invent them, and `secrets gen` invents better ones than you will.

`LITELLM_MASTER_KEY` · `LITELLM_SALT_KEY` · `NEXTAUTH_SECRET` · `LANGFUSE_SALT` · `CLICKHOUSE_PASSWORD` · `POSTGRES_PASSWORD` · `MINIO_ROOT_PASSWORD` · `ARTIFACT_MINIO_ROOT_USER` · `ARTIFACT_MINIO_ROOT_PASSWORD` · `VLLM_API_KEY`

```bash
./scripts/stack.sh secrets gen      # prints a fresh value for each of these
```

`VLLM_API_KEY` is in this list for a reason worth noticing: it is not issued by RunPod. You choose a value and pass it to `vllm serve --api-key` — see vLLM's [OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html) docs. That is what makes it easy to skip, and skipping it leaves [an open GPU on the internet](#security-posture).

With [headless initialization](#kind-3-the-langfuse-keys-which-look-like-an-ordering-trap-and-are-not), `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` belong in this list too — you choose them rather than fetch them.

### Kind 2 — a provider console (you need an account, possibly a payment method)

Each row links the **vendor's own guide**, not just the console, because the console layout changes more often than the docs do.

| Credential | Official guide | Console | What to create | Watch for |
|---|---|---|---|---|
| `OPENAI_API_KEY` | [API authentication](https://platform.openai.com/docs/api-reference/authentication/api-keys) · [reference overview](https://developers.openai.com/api/reference/overview#authentication) | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | a project-scoped key | shown **once**. A project with no credit returns 429 on the first call, which reads exactly like a bad key |
| `ANTHROPIC_API_KEY` | [Get started with Claude](https://docs.anthropic.com/en/docs/initial-setup) · [API overview](https://docs.anthropic.com/en/api/getting-started) | [console.anthropic.com](https://console.anthropic.com) | a workspace key, in Account Settings | also shown once, and you pick an **expiry date** at creation — a key that worked last quarter may simply have lapsed |
| `RUNPOD_API_KEY` | [Manage API keys](https://docs.runpod.io/get-started/api-keys) | Settings → API Keys | permission **Read Only** unless the script must start pods | RunPod does not store the key — if you lose it, you create a new one. Needs account balance before a pod starts. Phase 3 only |
| `CLICKHOUSE_CLOUD_HOST` / `_USER` / `_PASSWORD` | [Manage database users](https://clickhouse.com/docs/cloud/security/manage-database-users) · [Common access management queries](https://clickhouse.com/docs/cloud/security/common-access-management-queries) · [`CREATE USER`](https://clickhouse.com/docs/sql-reference/statements/create/user) | [clickhouse.cloud](https://clickhouse.cloud) → service → Settings | a **dedicated read-only user**, not an SQL-console login | an agent holding this has its full grants. Note SQL console statements run as `sql-console:<your-email>`, *not* as the user you create — so test the grants with the real credential, not in the console |
| AWS | [IAM Identity Center + CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) | `aws configure sso` | an SSO profile | prefer SSO. Leave the static key variables blank and Terraform picks up `AWS_PROFILE` |

### Kind 3 — the Langfuse keys, which look like an ordering trap and are not

`LANGFUSE_PUBLIC_KEY` · `LANGFUSE_SECRET_KEY`

The obvious path is: bring Langfuse up, open <http://localhost:3000>, create an organisation and project, copy the key pair out of project settings. That works, and it is what [Deployment](deployment.md#first-time-setup) currently describes.

It also creates a real ordering problem. LiteLLM reads the Langfuse keys **at startup** to configure its callbacks, so on a first run the gateway starts before the keys exist and traces silently do not appear — which is the single most common "nothing is broken but nothing works" symptom in this stack.

!!! tip "Headless initialization removes the two-pass dance entirely"
    Langfuse can create the org, project, user **and the key pair** on first boot from environment variables — see [Headless Initialization](https://langfuse.com/self-hosting/administration/headless-initialization). You choose the keys instead of collecting them:

    ```bash
    LANGFUSE_INIT_ORG_ID=llmops
    LANGFUSE_INIT_PROJECT_ID=sovereign-ai-stack
    LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-...      # you pick these
    LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-...      # same generator as any other secret
    LANGFUSE_INIT_USER_EMAIL=you@example.com
    LANGFUSE_INIT_USER_PASSWORD=...
    ```

    That moves both keys out of kind 3 and into **kind 1** — generated, not fetched — so the whole stack can come up correctly in one pass with no browser trip. `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` are then simply set to the same values.

    Caveats worth knowing: the variables only take effect **if the resources do not already exist**, so this initialises rather than reconciles; an org must be initialised before a project or user; `ORG_ID`, `PROJECT_ID`, both project keys, and the user's email and password are the required ones; and in Compose the values must not be double-quoted.

    This is the recommended path for this stack and the UI route is the fallback. Where a `.env` cannot hold them, note that Langfuse also documents a [public API](https://langfuse.com/docs/api-and-data-platform/features/public-api) and [SCIM/Org API](https://langfuse.com/docs/administration/scim-and-org-api) for provisioning. If you are ever unsure where a key lives, Langfuse has a page for exactly that question: [Where do I find my API keys?](https://langfuse.com/faq/all/where-are-langfuse-api-keys)

### Kind 4 — emitted by provisioning (copy the output)

| Credential | Comes from | Note |
|---|---|---|
| `VLLM_API_BASE` | the RunPod pod's HTTP proxy URL | **must end in `/v1`** — `https://<pod-id>-8000.proxy.runpod.net/v1` |
| `MCP_CLICKHOUSE_URL` | wherever the MCP server is reachable | Phase 2 |

### What this means for a first run

For **Phase 1** — the only phase that runs today — the actual human work is: **create two provider keys and run `secrets gen`.** With headless initialization that is the whole browser trip. Everything else is generated locally.

Phases 2–4 add credentials, but `doctor` stays quiet about them until you select that phase, so they are never in your way early.

---

## Automating the input

Filling this in by hand is the single most error-prone part of standing the stack up, and the errors surface late — usually as a failed request in front of an audience. Worth automating. The design matters more than the code, so here is the reasoning.

### Why a naive prompt loop is the wrong shape

"Iterate the inventory and ask for each value" fails on all three of the distinctions above:

- **About half should never be typed.** Prompting for `POSTGRES_PASSWORD` invites a human to choose a weak one. Kind 1 should be generated without asking.
- **Some should not be asked for at all.** Asking for `LANGFUSE_PUBLIC_KEY` before Langfuse is running has no correct answer — and with headless initialization it has no *question*, because the wizard should generate it and hand it to Langfuse. Asking for `VLLM_API_BASE` in Phase 1 is simply noise.
- **A typo survives until it costs something.** A key pasted with a trailing newline or from the wrong workspace looks identical to a good one in a file.

So the classification is not documentation — it is the control flow.

### The proposed flow

```
stack.sh secrets init [--phase N] [--only NAME] [--force] [--from-env]

  for each credential the selected phase needs:
    kind 1 (generate:)   → generate, write, never prompt
    kind 2 (console:)    → print the official guide URL, open the console,
                           read -rs, validate before accepting
    kind 4 (provisioned) → prompt, showing the expected shape
```

Note there is **no kind 3 branch**, and that is the design win. Because Langfuse accepts its key pair via `LANGFUSE_INIT_*`, the wizard generates those keys like any other secret and Langfuse adopts them on first boot. One pass, no browser trip for them, and no "traces are not appearing" phase to explain.

That is worth stating as a principle rather than a detail: **when a service will accept a credential you chose, choosing it is better than fetching it.** It removes an ordering dependency, a manual step, and a failure mode all at once.

### A validation ladder, cheapest first

| Level | Checks | Cost | Catches |
|---|---|---|---|
| **Shape** | prefix, length, no whitespace | free, offline | paste errors, truncation, trailing newline — most real mistakes |
| **Liveness** | one minimal authenticated call | one request | revoked keys, wrong account, no credit |
| **Scope** | the credential can do what is needed, **and not more** | a few requests | over-privileged credentials |

The third level is the one worth building deliberately, because it is the only one that catches a *dangerous* success. For the ClickHouse Cloud user, "valid" is not enough — the check should assert that a `SELECT` succeeds **and that a write fails**. A credential that passes both is verified least-privilege. A credential that passes only the first is a finding.

That inverts the usual instinct. Most credential validation asks *does this work?*; here the useful question is also *what else does this work for?*

### Handling the value safely inside the script

A wizard that collects secrets is a new place for secrets to leak. Non-negotiables:

- `read -rs` — never echo to the terminal, never leave it in a scrollback someone screen-shares
- **never pass a secret as an argument** — argv is world-readable via `ps`; use stdin or the environment
- `set +x` around the block, so running the script with tracing on does not print every value
- `umask 077` before writing, and write to a temp file in the same directory then `mv` — atomic, with no window where a half-written file has loose permissions
- unset the variable as soon as it is persisted

### Idempotency, because setup gets interrupted

- an entry that already has a value is **skipped**, not re-asked, unless `--force` or `--only`
- a run that dies halfway leaves earlier answers intact and can be resumed
- nothing is overwritten silently — that is how a working key gets replaced by a typo

### Where this actually wants to end up

`stack.yaml` already declares the seam:

```yaml
secrets:
  provider: dotenv          # dotenv | aws-ssm | vault
```

Only `dotenv` is implemented, but the field is the right abstraction and the wizard should be written against it from the start: **collection and persistence are separate concerns.** A demo persists to `.env`; a real deployment persists to SSM Parameter Store or Vault and never writes a file at all.

Building the wizard to assume a file is how "just for the demo" quietly becomes the production path. Building it against the provider seam means the production story is a backend, not a rewrite.

### What deliberately stays manual

- **Creating accounts and adding payment methods.** That is a purchasing decision with a human owner, and scripting it buys nothing.
- **Rotating provider keys from the same script that stores them.** Rotation should be initiated where revocation happens — at the provider.
- **Scraping the Langfuse UI for its keys.** Brittle against every release. The two-pass prompt is honest and stable.

---

## Inventory format

Each entry records more than a value — where to get it, what scopes it needs, who owns it, and how often to rotate. The file doubles as an audit artifact rather than a bag of strings.

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
  owner: ""
  rotates: 90d
```

| Field | Purpose |
|---|---|
| `env` | The variable name the stack reads — must match `stack.yaml` `secrets:` |
| `value` | The secret itself. Empty in the committed template |
| `console` | Where to obtain or rotate it |
| `generate` | Shell command producing a value, for self-generated secrets |
| `scopes` | Least-privilege grants this credential should have |
| `phase` | Which build-out phase needs it |
| `owner` / `rotates` | Accountability and cadence for audits |

---

## Ignore coverage

`secrets/credentials.yaml` and `.env` are excluded from git, from Docker build contexts, and from every AI coding tool with a repo-level exclusion mechanism.

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

!!! danger "GitHub Copilot is the exception"
    Copilot has **no repo-level ignore file**. Content exclusions are configured server-side, per repository or organisation, under *Settings → Copilot → Content exclusions*. Add `secrets/**`, `.env`, and `**/*.tfvars` there.

    Until you do, assume Copilot can see these files.

### Verifying

```bash
./scripts/stack.sh secrets audit
```

```console
==> Ignore coverage
  ✓ git ignores .env
  ✓ git ignores secrets/credentials.yaml
  ✓ .dockerignore covers secrets/ and .env
  ✓ .cursorignore covers secrets/ and .env
  ...
  ✓ .claude/settings.json denies Read on secrets/
==> Nothing sensitive tracked
  ✓ .env not in the index
  ✓ secrets/credentials.yaml not in the index
  ✓ .env absent from history
  ✓ secrets/credentials.yaml absent from history
==> Committed template is value-free
  ✓ credentials.example.yaml has no real values

secrets audit passed
```

The audit checks three separate things, because they fail independently:

1. **Ignore rules exist** in all twelve mechanisms.
2. **Nothing is tracked** — not in the index, and *not anywhere in git history*. A file can be correctly ignored today and still be sitting in a commit from last week.
3. **The committed template is value-free** — the one file in `secrets/` that *is* committed must never gain a real value.

Run it before committing anything under `secrets/`.

---

## Security posture

!!! warning "`LITELLM_MASTER_KEY` is the crown jewel"
    It fronts every provider key. Clients only ever see this one credential — which is the point of a gateway — but it means leaking it exposes **all** downstream spend, not just one provider.

!!! warning "`VLLM_API_KEY` is not optional in practice"
    The RunPod HTTP proxy is public by default. A pod started without `--api-key` is an **open GPU on the internet**. Always set it.

!!! warning "Never open the security group to `0.0.0.0/0`"
    The demo ports are unauthenticated by default and the stack holds live provider keys. Set `allowed_cidr` to your own IP as `<ip>/32`.

**Prefer AWS IAM Identity Center** (`AWS_PROFILE` via `aws configure sso`) over static access keys. If SSO is available, leave `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` blank — Terraform picks up the profile.

**Scope tool credentials tightly.** From Phase 2 an agent can call tools, and it holds whatever grants the credential has. A read-only ClickHouse Cloud user is the difference between an agent that can answer questions and one that can `DROP TABLE`.

---

## If a credential leaks

1. **Revoke first, at the provider.** Rotating the value in your file does nothing to a key that has already been pushed. Assume anything committed is compromised the moment it lands.
2. Issue a replacement and run `./scripts/stack.sh secrets write`.
3. *Only then* clean history (`git filter-repo`, or delete the repo if it is young).
4. Note the rotation in `meta.last_reviewed`.

!!! danger "History rewriting is not containment"
    Forks, clones, CI caches, and GitHub's own unreachable-object storage can all retain the blob. Revocation is the control that actually works; rewriting history is cleanup.
