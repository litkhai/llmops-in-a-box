# Task: PR 4 — Wire AWS target into stack.sh

## Branch
`pr/4-stack-aws-wire` — base: `main`

## Goal
Add two new capabilities to `scripts/stack.sh`:
1. `secrets push` — pushes Phase 1 credentials to SSM Parameter Store so the
   EC2 bootstrap script (PR 3) can pull them
2. `ssh` — quick SSH into the aws-ec2 target for log inspection

Also add `ssm_path_prefix` to `stack.yaml` under `targets.aws-ec2.vars` so
the path is declared once.

And add a post-provision wait loop to `cmd_up()` for terraform targets so
`stack.sh up --target aws-ec2` polls until the bootstrap completes.

## Context: existing code you must understand first

Read `scripts/stack.sh` before editing. Key sections:

- **`cmd_up()` (line ~1723)**: terraform case already calls `terraform init`
  and `terraform apply`. After apply, add a polling loop.
- **`cmd_secrets()` (line ~1644)**: dispatches to subcommands. Add `push` here.
- **`target_host()` (line ~200)**: already reads `public_ip` from terraform output.
  `cmd_status` and `cmd_urls` work for remote targets automatically.
- **`cmd_logs()` (line ~1841)**: only works for compose targets. `cmd_ssh` is
  the analog for terraform targets.
- **`usage()` (line ~1850)**: add entries for `push` and `ssh`.
- **`main()` dispatch (line ~1945)**: add `ssh` case.
- **`main()` secrets subcommand parser (line ~1908)**: add `push` to valid subcommands.

Bash 3.2 compatibility is required throughout (no `[[`, no `${var^^}`,
no associative arrays, no `readarray`).

## Changes required

### 1. `stack.yaml` — add `ssm_path_prefix` to aws-ec2 vars

Read `stack.yaml`. Under `targets.aws-ec2.vars`, add one line:

```yaml
      ssm_path_prefix: /sais/phase-1
```

### 2. `scripts/stack.sh` — new function `cmd_secrets_push()`

Add this function BEFORE `cmd_secrets()` (around line 1644):

```bash
cmd_secrets_push() {
  # Push all set Phase 1 credentials to SSM Parameter Store.
  # The EC2 bootstrap script pulls them from SSM at first boot.
  # Requires: aws CLI configured with ssm:PutParameter on the path below.
  command -v aws >/dev/null 2>&1 \
    || die "aws CLI not found — install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

  local region prefix s val path pushed=0 skipped=0
  region="$(qs ".targets.\"aws-ec2\".vars.region")"
  prefix="$(qs ".targets.\"aws-ec2\".vars.ssm_path_prefix")"
  [ -n "$region" ] || region="ap-northeast-2"
  [ -n "$prefix" ] || prefix="/sais/phase-1"

  load_env
  info "Pushing secrets to SSM  ${C_DIM}region=$region  prefix=$prefix${C_RST}"
  warn "Parameters are encrypted with the default AWS KMS key"

  for s in $(q '.secrets.required[]') $(q '.secrets.optional."1"[]'); do
    val="${!s:-}"
    if [ -z "$val" ]; then
      warn "$(printf '%-34s' "$s") unset — skipping"
      skipped=$((skipped + 1))
      continue
    fi
    path="$prefix/$s"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  [dry-run] aws ssm put-parameter --name $path --type SecureString"
    else
      aws ssm put-parameter \
        --region "$region" \
        --name   "$path" \
        --value  "$val" \
        --type   SecureString \
        --overwrite \
        --no-cli-pager >/dev/null
      ok "$(printf '%-34s' "$s") → $path"
    fi
    pushed=$((pushed + 1))
  done

  say ""
  say "  pushed=$pushed  skipped=$skipped"
  [ "$skipped" -eq 0 ] || warn "skipped credentials will not be available on EC2 — run 'secrets status' to review"
  [ "$DRY_RUN" -eq 0 ] && say "  ${C_DIM}Verify: aws ssm get-parameters-by-path --region $region --path $prefix --with-decryption${C_RST}"
}
```

### 3. `scripts/stack.sh` — update `cmd_secrets()` dispatch

In `cmd_secrets()`, add `push)` alongside the existing subcommands:

```bash
    push)   cmd_secrets_push ;;
```

### 4. `scripts/stack.sh` — update `main()` secrets subcommand parser

Around line 1910, the parser lists valid secrets subcommands. Add `push`:

```bash
      init|setup|set|generate|gen|status|validate|write|audit|push)
```

### 5. `scripts/stack.sh` — post-provision wait in `cmd_up()` terraform case

In `cmd_up()`, inside the `terraform)` case, AFTER the existing
`run terraform -chdir="$d" apply ...` line, add:

```bash
      # After apply, the EC2 bootstrap script installs Docker and starts the
      # stack. Poll LiteLLM until it responds or the timeout expires.
      if [ "$DRY_RUN" -eq 0 ]; then
        local host elapsed=0 wait_to=300 code
        host="$(target_host)"
        info "Waiting for bootstrap on $host (up to ${wait_to}s)"
        while [ "$elapsed" -lt "$wait_to" ]; do
          code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://$host:4000/health/liveliness" 2>/dev/null || true)"
          case "$code" in
            2*|3*) ok "LiteLLM responded ($code) after ${elapsed}s"; break ;;
          esac
          sleep 10
          elapsed=$((elapsed + 10))
        done
        if [ "$elapsed" -ge "$wait_to" ]; then
          warn "stack did not respond within ${wait_to}s"
          warn "check: ssh ec2-user@$host 'tail -50 /var/log/bootstrap-ec2.log'"
        fi
      fi
```

### 6. `scripts/stack.sh` — new function `cmd_ssh()`

Add after `cmd_logs()` (around line 1847), before `usage()`:

```bash
cmd_ssh() {
  resolve_defaults
  local kind; kind="$(qs ".targets.\"$TARGET\".kind")"
  [ "$kind" = "terraform" ] || die "'ssh' is only available for terraform targets (got: $TARGET)"
  local host
  host="$(target_host)"
  [ -n "$host" ] || die "could not resolve host — run './scripts/stack.sh urls' after terraform apply"
  if [ -n "${SSH_KEY_PATH:-}" ]; then
    run ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$host" "${EXTRA_ARGS:-}"
  else
    run ssh -o StrictHostKeyChecking=no "ec2-user@$host" "${EXTRA_ARGS:-}"
  fi
}
```

### 7. `scripts/stack.sh` — update `usage()`

Add to the COMMANDS section:
```
  secrets push       Push set credentials to SSM Parameter Store (for aws-ec2 target)
  ssh         SSH into the aws-ec2 target (set SSH_KEY_PATH or use ssh-agent)
```

### 8. `scripts/stack.sh` — update `main()` dispatch

Add before the `*) die` catch-all:
```bash
    ssh)    require_yq; cmd_ssh ;;
```

## Validation (run before committing)

```bash
bash -n scripts/stack.sh
yq -e '.' stack.yaml >/dev/null

# Confirm new commands appear in help
./scripts/stack.sh help | grep -E 'smoke-test|push|ssh'

# Dry-run push (no real AWS call)
./scripts/stack.sh secrets push --dry-run 2>&1 | head -5
```

## Commit

```
git add scripts/stack.sh stack.yaml
git commit -m "Add secrets push to SSM, ssh helper, and post-provision wait for aws-ec2"
```

## PR

```bash
gh pr create \
  --base main \
  --head pr/4-stack-aws-wire \
  --title "Add secrets push, ssh helper, and post-provision wait for aws-ec2" \
  --body "$(cat <<'EOF'
## Summary
- Adds \`./scripts/stack.sh secrets push --target aws-ec2\`: uploads all set Phase 1 credentials to SSM Parameter Store as SecureString parameters under \`/sais/phase-1/\`
- Adds \`./scripts/stack.sh ssh --target aws-ec2\`: SSH convenience wrapper that resolves the EC2 public IP from terraform output
- Updates \`stack.sh up --target aws-ec2\` to poll LiteLLM for up to 5 minutes after \`terraform apply\`, giving the bootstrap script time to complete
- Adds \`ssm_path_prefix\` to \`stack.yaml\` aws-ec2 vars — single source of truth for the SSM path

## What already works (no changes needed)
\`target_host()\` already reads \`public_ip\` from terraform output, so \`status\`, \`urls\`, and health checks already work for remote targets once the instance is up.

## Test plan
- [ ] \`./scripts/stack.sh secrets push --dry-run\` prints expected \`aws ssm put-parameter\` calls
- [ ] \`bash -n scripts/stack.sh\` reports no syntax errors
- [ ] \`./scripts/stack.sh help\` shows \`secrets push\` and \`ssh\`
- [ ] After a real \`up --target aws-ec2\`, the wait loop exits OK once bootstrap finishes

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Working agreements (from AGENTS.md)
- Keep `scripts/stack.sh` compatible with macOS Bash 3.2
- Never inspect, print, or commit values from `.env` or `secrets/credentials.yaml`
- `cmd_secrets_push` reads values via the env (already loaded by `load_env`) —
  it must not print them
- Update `docs/` when behavior or commands change — that is PR 5
