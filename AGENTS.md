# Repository guidance for Codex

## Project

This repository is a reference architecture and deployment toolkit for a
composable LLMOps stack. `stack.yaml` is the source of truth for phases,
profiles, layers, models, secret names, and deployment targets.

## Working agreements

- Keep changes aligned with the current phase declared in `stack.yaml`.
- Edit `stack.yaml`, not generated model configuration, then run
  `./scripts/stack.sh render`.
- Keep `scripts/stack.sh` compatible with macOS Bash 3.2.
- Never inspect, print, commit, or copy values from `.env` or
  `secrets/credentials.yaml`. Commands may consume them through the project's
  expected environment mechanism, but output must not reveal them. Use
  `.env.example` and `secrets/credentials.example.yaml` when structure is
  needed.
- Preserve the `airgapped` invariant: it must not render commercial models or
  commercial-model fallbacks.
- Update README and `docs/` when behavior, commands, profiles, phases, or
  architecture change.
- Do not claim a layer or target is implemented until its deployable artifact
  and a meaningful validation path exist.
- Preserve unrelated user changes in the working tree.
- When Codex materially contributes to a commit, append
  `Co-authored-by: Codex <codex@openai.com>` to the commit message.

## Validation

Run the checks relevant to the files changed:

```bash
bash -n scripts/stack.sh
yq -e '.' stack.yaml >/dev/null
./scripts/stack.sh config
./scripts/stack.sh models
./scripts/stack.sh secrets audit
mkdocs build --strict
```

When model or routing configuration changes, render every affected profile and
verify that generated LiteLLM and LibreChat model lists agree. When deployment
artifacts exist, also run their native config validation before reporting the
work complete.

## Review priorities

Review changes in this order:

1. Secret exposure, unintended egress, authentication, and destructive actions.
2. Drift between `stack.yaml`, rendered configuration, deployment artifacts,
   and documentation.
3. Profile dependency resolution, fallback behavior, and phase readiness.
4. Health checks, observability metadata, reproducibility, and rollback.
