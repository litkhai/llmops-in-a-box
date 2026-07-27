# Task: PR 1 — Docker validation smoke-test and EE license check

## Branch
`pr/1-docker-validation` — base: `main`

## Goal
Add `./scripts/stack.sh smoke-test` and improve `doctor` to surface the
Langfuse Enterprise Edition license status. No new infrastructure. No new
files outside `scripts/stack.sh` and `docs/getting-started.md`.

## Changes required

### 1. `scripts/stack.sh` — new function `cmd_smoke_test()`

Insert after `cmd_status()` (around line 1839), before `cmd_logs()`:

```bash
cmd_smoke_test() {
  resolve_defaults; load_env
  local host fail=0 code body model
  host="$(target_host)"
  model="$(resolved_models | head -1)"
  [ -n "$model" ] || die "no models resolved for profile=$PROFILE"

  info "Smoke test  ${C_DIM}host=$host  model=$model${C_RST}"

  # 1. LiteLLM liveness
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://$host:4000/health/liveliness" 2>/dev/null || true)"
  case "$code" in
    2*|3*) ok "$(printf '%-16s' litellm) $code" ;;
    *)     bad "$(printf '%-16s' litellm) ${code:-no-response}"; fail=1 ;;
  esac

  # 2. Langfuse liveness
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://$host:3000/api/public/health" 2>/dev/null || true)"
  case "$code" in
    2*|3*) ok "$(printf '%-16s' langfuse) $code" ;;
    *)     bad "$(printf '%-16s' langfuse) ${code:-no-response}"; fail=1 ;;
  esac

  # 3. Chat completion round-trip through LiteLLM
  if [ "$fail" -eq 0 ]; then
    local tmp; tmp="$(mktemp)"
    code="$(curl -s -o "$tmp" -w '%{http_code}' --max-time 30 \
      -X POST "http://$host:4000/chat/completions" \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY:-}" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
      2>/dev/null || true)"
    case "$code" in
      2*) ok "$(printf '%-16s' chat_completion) $code  model=$model" ;;
      *)  bad "$(printf '%-16s' chat_completion) ${code:-no-response}"; cat "$tmp" >&2; fail=1 ;;
    esac
    rm -f "$tmp"
  fi

  say ""
  if [ "$fail" -eq 0 ]; then say "${C_GRN}${C_B}smoke test passed${C_RST}"
  else die "smoke test failed — fix the ✗ items above"; fi
}
```

Constraints:
- bash 3.2 compatible: no `[[`, no `${var^^}`, no associative arrays
- Use `printf` not `echo`
- `mktemp` without `-p` for macOS compatibility
- Follow the style of `cmd_status()` exactly

### 2. `scripts/stack.sh` — update `cmd_doctor()`

After the existing "Secrets" info block (around line 408), add an
"Observability" check that runs when the `observability` layer is active:

```bash
  if resolved_layers | grep -qx observability; then
    info "Observability"
    if [ -n "${LANGFUSE_EE_LICENSE_KEY:-}" ]; then
      ok "Langfuse EE license set"
    else
      warn "LANGFUSE_EE_LICENSE_KEY unset — running Langfuse OSS (no SSO, no data-retention policy, no audit log)"
    fi
  fi
```

### 3. `scripts/stack.sh` — update `usage()`

Add to the COMMANDS section (after `status`):
```
  smoke-test  Send a test request end-to-end and verify the trace pipeline
```

### 4. `scripts/stack.sh` — update `main()` dispatch

Add before the `*) die ...` catch-all:
```bash
    smoke-test) require_yq; cmd_smoke_test ;;
```

### 5. `docs/getting-started.md`

Read the file first. Add a short "Verify the stack" section (3–5 lines)
after the section that describes starting the stack, pointing to
`./scripts/stack.sh smoke-test` as the end-to-end check.

## Validation (run before committing)

```bash
bash -n scripts/stack.sh
./scripts/stack.sh help | grep smoke-test
yq -e '.' stack.yaml >/dev/null
mkdocs build --strict
```

## Commit

```
git add scripts/stack.sh docs/getting-started.md
git commit -m "Add smoke-test command and Langfuse EE license check in doctor"
```

## PR

```bash
gh pr create \
  --base main \
  --head pr/1-docker-validation \
  --title "Add smoke-test command and Langfuse EE license check" \
  --body "$(cat <<'EOF'
## Summary
- Adds \`./scripts/stack.sh smoke-test\`: hits LiteLLM and Langfuse health endpoints, then sends a real chat completion to verify the full request path
- Updates \`doctor\` to flag Langfuse EE license status separately under an Observability section
- Documents the smoke-test step in getting-started

## Test plan
- [ ] \`./scripts/stack.sh smoke-test\` exits 0 with the Phase 1 stack running and real keys set
- [ ] \`./scripts/stack.sh smoke-test\` exits non-zero when LiteLLM is not running
- [ ] \`./scripts/stack.sh doctor\` shows EE license status under Observability
- [ ] \`./scripts/stack.sh help\` lists smoke-test

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Working agreements (from AGENTS.md)
- Keep `scripts/stack.sh` compatible with macOS Bash 3.2
- Never inspect, print, or commit values from `.env` or `secrets/credentials.yaml`
- Update `docs/` when behavior or commands change
- Do not claim a feature is implemented until a meaningful validation path exists
