# Credentials

All provider keys and local service credentials are inventoried in one private
file:

```text
secrets/credentials.yaml  ── secrets write ──>  .env  ──>  runtime
       private, 0600                         generated, 0600
```

`secrets/credentials.yaml` is the source of truth. `.env` is generated and
overwritten; do not edit it manually. Commands mask stored values unless the
user explicitly chooses to reveal one.

## First-time setup

```bash
./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1
```

Use the setup menu in this order:

1. `d` — set the demo's default ID, email, and password.
2. Open **Model providers** and enter at least one provider key.
3. `g` — generate missing internal values.
4. `w` — validate and write `.env`.
5. `q` — finish.

Then verify without printing values:

```bash
./scripts/stack.sh secrets status --phase 1
./scripts/stack.sh secrets validate --phase 1
./scripts/stack.sh doctor
```

### Menu reference

| Context | Key | Action |
|---|:---:|---|
| Main menu | `d` | Set default login fields available in the current filter |
| Main menu | `g` | Generate missing internal values |
| Main menu | `w` | Validate and atomically write `.env` |
| Main menu | `q` / Enter | Finish |
| Group | number | Select a credential |
| Configured value | `c` | Copy it to the clipboard |
| Configured value | `r` | Reveal after a scrollback warning |
| Configured value | `e` | Replace and validate |
| Configured value | `d` | Delete |
| Generated value | `g` | Generate or regenerate |
| Submenu | `b` | Go back |

With `--phase 1`, the default action prompts for ID, email, and password. The
email maps to `LANGFUSE_INIT_USER_EMAIL`; it is not requested simply by opening
the setup menu. A phase or `--only` filter with no email target omits the
prompt.

The default mapping is semantic:

| Default | Destinations |
|---|---|
| ID | LiteLLM UI, local ClickHouse, PostgreSQL, MinIO accounts |
| Email | Langfuse initial user |
| Password | Compatible local service logins |

Provider keys, LiteLLM gateway keys, JWTs, salts, and encryption keys remain
unique. Shared logins are convenient for a disposable local demo but should be
replaced with per-service credentials in production.

## Where values come from

### External accounts

These values must be obtained from their provider or environment:

| Scope | Credentials | Note |
|---|---|---|
| Phase 1 models | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | At least one is needed for the workshop |
| Optional Langfuse | `LANGFUSE_EE_LICENSE_KEY` | Leave blank for the OSS feature set |
| Phase 1 Langfuse tracing | `CLICKHOUSE_CLOUD_HOST`, `LANGFUSE_CLICKHOUSE_USER`, `LANGFUSE_CLICKHOUSE_PASSWORD` | ClickHouse Cloud host and writer credentials for the `llmops` database |
| Phase 2 MCP | `CLICKHOUSE_CLOUD_USER`, `CLICKHOUSE_CLOUD_PASSWORD` | ClickHouse Cloud admin credentials — use a dedicated read-only database user |
| Phase 1 image gen | `CF_API_TOKEN`, `CF_ACCOUNT_ID` | Free tier; absent silently disables image generation |
| Phase 4 GPU serving | `RUNPOD_API_KEY`, `VLLM_API_BASE`, `VLLM_API_KEY` | The vLLM base URL must end in `/v1` |
| AWS target | `AWS_PROFILE` or a static access-key pair | Prefer IAM Identity Center / SSO |

The `console` and `notes` fields in the credential inventory contain the
provider-specific acquisition and scope guidance.

AWS accepts either:

- `AWS_PROFILE` for SSO, or
- both `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

Static keys are not required when an SSO profile is selected.

### Locally generated values

Internal gateway keys, salts, encryption values, JWT secrets, database
passwords, and demo Langfuse project keys are generated offline:

```bash
./scripts/stack.sh secrets generate --phase 1
```

Existing values are preserved unless `--force` is explicitly supplied. The
setup menu's `g` shortcut fills missing generated values across the inventory,
including harmless future-phase values.

Langfuse project keys are chosen before first boot and passed through
`LANGFUSE_INIT_*`. This lets Langfuse create the organization, project, user,
and key pair while LiteLLM starts with tracing already configured.

## Domain configuration (aws-ec2)

The domain and SSL email for the Caddy HTTPS proxy are not secrets but are
pushed to SSM alongside credentials so the EC2 bootstrap can read them from
one place:

```bash
./scripts/stack.sh secrets domain
# prompts for DOMAIN_BASE (e.g. example.com) and DOMAIN_SSL_EMAIL
# writes both to .env

./scripts/stack.sh secrets push --target aws-ec2
# pushes DOMAIN_BASE and DOMAIN_SSL_EMAIL to SSM along with all other credentials
```

These values are listed under `secrets.optional."1"` in `stack.yaml` so
`secrets push` picks them up automatically.

## Image generation (free tier)

Image generation is handled by Cloudflare Workers AI (FLUX.1-schnell), called
directly from the `UnifiedRouter` callback. The provider offers a free tier with
no credit card required. If the tokens are absent, image generation fails with an
API error; the chat path is unaffected.

| Variable | Where to get it |
|---|---|
| `CF_API_TOKEN` | [dash.cloudflare.com](https://dash.cloudflare.com/) → "My Profile" → "API Tokens" → "Create Token" → use the **Cloudflare Workers AI** template → copy. |
| `CF_ACCOUNT_ID` | Top-right of any Cloudflare dashboard page under **Account ID**. |

Enter these through the setup menu (they appear under the
"Image generation (Cloudflare Workers AI)" group):

```bash
./scripts/stack.sh secrets setup --phase 1
```

## MCP (ClickHouse Cloud)

The `mcp-clickhouse` service connects to ClickHouse Cloud using three
credentials. Use a **dedicated read-only user** — the MCP server's database
grants are the only access control; prompt instructions are not.

| Variable | Where to get it |
|---|---|
| `CLICKHOUSE_CLOUD_HOST` | ClickHouse Cloud console → your service → **Connect** → hostname (without port) |
| `CLICKHOUSE_CLOUD_USER` | ClickHouse Cloud console → a read-only SQL user you create |
| `CLICKHOUSE_CLOUD_PASSWORD` | Password for that user |

Enter these through the setup menu:

```bash
./scripts/stack.sh secrets setup --phase 2
```

These values are pushed to SSM under the `phase-2` prefix when deploying to
the aws-ec2 target:

```bash
./scripts/stack.sh secrets push --target aws-ec2
```

`MCP_CLICKHOUSE_URL` is derived automatically from the host and does not need
to be set manually.

## Focused and automated use

```bash
./scripts/stack.sh secrets setup --phase 3
./scripts/stack.sh secrets set OPENAI_API_KEY
./scripts/stack.sh secrets status --all
./scripts/stack.sh secrets validate --all
./scripts/stack.sh secrets write
```

`set` uses hidden terminal input and validates before persisting. `write`
creates `.env` atomically with mode `600`. Setup is resumable and does not
replace configured values without an explicit replace, delete, regenerate, or
confirmed default action.

Validation is offline. It checks prefixes, lengths, whitespace, URLs, AWS
identifiers, and unsafe CIDRs. It does **not** prove that a provider key is
funded, unexpired, live, or least-privileged. Those checks require
provider-specific authenticated requests.

## Inventory format

The committed `secrets/credentials.example.yaml` defines the structure without
values:

```yaml
- name: ClickHouse Cloud user
  phase: 2
  env: CLICKHOUSE_CLOUD_USER
  value: ""
  input: config
  console: https://clickhouse.cloud
  scopes: [SELECT]
  owner: ""
  rotates: 90d
```

Important fields:

| Field | Purpose |
|---|---|
| `env` | Runtime variable name; must agree with `stack.yaml` |
| `value` | Private value, empty in the committed template |
| `input` | External hidden input, visible config, or committed default |
| `generate` | Allowlisted local generator |
| `default_credential` | Optional `id`, `email`, or `password` mapping |
| `required` | Whether an empty value is an error |
| `phase` | First phase that needs the value |
| `scopes`, `owner`, `rotates` | Least privilege and accountability |

## Storage and ignore coverage

The private inventory and `.env` are excluded from Git, Docker build contexts,
and supported AI-tool indexes. Verify the rules and Git history with:

```bash
./scripts/stack.sh secrets audit
```

The audit checks:

- Git ignore rules and tracking history
- Docker build-context exclusions
- repository ignore files for Claude Code, Cursor, JetBrains AI Assistant,
  Gemini, Codeium/Windsurf, Aider, Continue, and Codex
- that the committed example contains no real values

GitHub Copilot has no repository ignore file. Configure content exclusions in
GitHub settings for `secrets/**`, `.env`, and `**/*.tfvars`; otherwise assume
Copilot can access them.

## Operational cautions

- Never pass a secret as a command argument or enable shell tracing around it.
- Use `r` only when terminal scrollback exposure is acceptable.
- Clear the clipboard after copying a credential.
- `LITELLM_MASTER_KEY` fronts downstream provider access and spend; protect it
  accordingly.
- Set a `VLLM_API_KEY` before exposing a RunPod proxy.
- The `allowed_cidr` for the AWS EC2 target defaults to `0.0.0.0/0`; each service has its own application-level authentication. Restrict it further if you want network-level access control in addition.
- Changing `.env` does not rotate accounts already persisted by databases or
  object stores.
- Preserve `LANGFUSE_ENCRYPTION_KEY`; losing it can make stored encrypted data
  unreadable.

## If a credential leaks

1. Revoke it at the provider immediately.
2. Issue a replacement and update the inventory.
3. Run `./scripts/stack.sh secrets write`.
4. Clean Git history only after revocation.

History rewriting is cleanup, not containment: forks, clones, and caches can
retain the original value.
