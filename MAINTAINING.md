# MAINTAINING.md

Checks to run and the order to review changes in. Agents read this before reporting work complete
or reviewing a change. Project rules: [`AGENTS.md`](AGENTS.md).

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
