# `secrets/`

Only this file and `credentials.example.yaml` are committed. The real
`credentials.yaml` and generated `.env` must stay private.

## Setup

```bash
./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1
# main menu: d → provider key(s) → g → w → q

./scripts/stack.sh secrets status --phase 1
./scripts/stack.sh secrets validate --phase 1
./scripts/stack.sh doctor
```

`credentials.yaml` is the source of truth; `.env` is generated from it. Never
edit `.env` manually.

The setup menu:

| Key | Action |
|:---:|---|
| `d` | Set compatible default ID, email, and password fields |
| `g` | Generate missing internal values |
| `w` | Validate and atomically write `.env` |
| `q` | Finish |

Within a credential, use `c` to copy, `r` to reveal after a warning, `e` to
replace, `d` to delete, and `b` to return. External input is hidden; generated
values are not printed.

Focused commands remain available:

```bash
./scripts/stack.sh secrets set OPENAI_API_KEY
./scripts/stack.sh secrets generate --phase 1
./scripts/stack.sh secrets write
```

See the published [Credentials](../docs/credentials.md) guide for the full
inventory, default mappings, AWS SSO/static-key choices, and validation limits.

## Verify ignore coverage

```bash
./scripts/stack.sh secrets audit
```

The audit verifies that private files are ignored by Git and Docker, absent
from Git history, excluded by supported AI-tool ignore files, and that the
committed example has no values.

GitHub Copilot content exclusions are configured in GitHub rather than in a
repository file. Exclude `secrets/**`, `.env`, and `**/*.tfvars`; otherwise
assume Copilot can access them.

## If a credential leaks

1. Revoke it at the provider.
2. Issue and store a replacement.
3. Run `./scripts/stack.sh secrets write`.
4. Clean history only after revocation.

History rewriting is cleanup, not containment.

## Cautions

- Protect `LITELLM_MASTER_KEY`; it fronts downstream provider access.
- Prefer AWS IAM Identity Center (`AWS_PROFILE`) to static keys.
- Authenticate any public vLLM/RunPod endpoint.
- Never expose the planned AWS target through `0.0.0.0/0`.
- Use `r` only when terminal scrollback exposure is acceptable.
