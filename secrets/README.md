# `secrets/`

Everything in this directory is ignored **except** this file and
`credentials.example.yaml`. Real credentials never enter git history, a Docker
build context, or an AI coding tool's index.

## Setup

```bash
./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1 # inside: d, provider keys, g, w
./scripts/stack.sh secrets status --all    # values are never printed
./scripts/stack.sh secrets validate --all  # offline format checks
./scripts/stack.sh secrets write           # atomic .env write, mode 600
./scripts/stack.sh doctor
```

`credentials.yaml` is the private source of truth. The setup hub handles
external values, visible configuration, shared login defaults, and locally
generated secrets with the appropriate input mode. `.env` is generated from it
and is what LiteLLM, Langfuse, LibreChat, and Terraform actually read. Never
hand-edit `.env`.

```
secrets/credentials.yaml  ──secrets write──►  .env  ──►  docker compose / terraform
      (private, 0600)                   (generated, 0600)
```

Operate on one phase or one credential when needed:

```bash
./scripts/stack.sh secrets generate --phase 1
./scripts/stack.sh secrets set OPENAI_API_KEY
./scripts/stack.sh secrets status --phase 1
./scripts/stack.sh secrets validate --phase 1
```

`secrets setup` is the unified setup hub. It groups the complete inventory by
technology, hides external secret input, accepts visible configuration values,
generates individual internal credentials, and offers `g` to generate every
missing internal value. Use `d` to set a default ID, email, and password:
LiteLLM receives the ID, Langfuse receives the email, and local databases and
object stores receive the compatible account fields;
cryptographic and external keys remain unique. This is a demo convenience;
prefer unique service passwords in production. Use `w` in the same menu to
write `.env`. The separate
`secrets generate` and `secrets write` commands remain available for
automation. Existing generated values are preserved unless `--force` is
supplied to `secrets generate`. Configured values remain hidden by default;
select an item and use `c` to copy it or `r` to reveal it after confirmation.

## Verifying the ignore coverage

```bash
./scripts/stack.sh secrets audit
```

This checks that `credentials.yaml` and `.env` are ignored by git, are absent
from the index and from `HEAD`, and that every ignore file below still lists
them. Run it before any commit that touches this directory.

## Coverage

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

**GitHub Copilot is the exception** — it has no repo-level ignore file.
Content exclusions are configured server-side, per repository or organisation,
under *Settings → Copilot → Content exclusions*. Add `secrets/**`, `.env`, and
`**/*.tfvars` there. Until you do, assume Copilot can see these files.

## If a credential leaks

1. **Revoke first, at the provider.** Rotating the value in this file does
   nothing to a key already pushed — assume anything committed is compromised.
2. Issue a replacement and run `./scripts/stack.sh secrets write`.
3. Only then clean history (`git filter-repo`, or delete the repo if it is
   young). History rewriting is not containment; revocation is.
4. Note the rotation date in `meta.last_reviewed`.

## Notes

- `LITELLM_MASTER_KEY` fronts every provider key. It is the highest-value
  secret here — leaking it exposes all downstream spend, not just one provider.
- Prefer AWS IAM Identity Center (`AWS_PROFILE`) over static access keys.
- `VLLM_API_KEY` is not optional in practice: the RunPod HTTP proxy is public
  by default, so an unauthenticated pod is an open GPU on the internet.
- Never set `AWS_ALLOWED_CIDR` to `0.0.0.0/0`. The demo ports are
  unauthenticated by default and the stack holds live provider keys.
