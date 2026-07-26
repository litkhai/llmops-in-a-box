#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
#  stack.sh — Sovereign AI Stack control plane
#
#  stack.yaml says WHAT the stack is. This script decides WHERE it runs and
#  renders the model catalog into the tool-specific configs.
#
#      ./scripts/stack.sh doctor
#      ./scripts/stack.sh up --target docker --profile phase-1
#      ./scripts/stack.sh status
#      ./scripts/stack.sh down
#
#  Deliberately bash 3.2 compatible (macOS system bash): no associative
#  arrays, no readarray, no ${var^^}.
# ═════════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_FILE="${STACK_FILE:-$REPO_ROOT/stack.yaml}"

TARGET=""
PROFILE=""
DRY_RUN=0
DO_RENDER=1
PURGE=0
SHOW_ALL=0
TF_VARS=""   # newline-separated key=value

# ── output ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
  C_RST=""; C_DIM=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
bad()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ── yq helpers ───────────────────────────────────────────────────────────────
# q: raw read. qs: read scalar, mapping YAML null -> empty string.
q()  { yq "$1" "$STACK_FILE"; }
qs() { local v; v="$(yq "$1" "$STACK_FILE")"; [ "$v" = "null" ] && v=""; printf '%s' "$v"; }

require_yq() {
  command -v yq >/dev/null 2>&1 || die "yq not found. Install it:  brew install yq"
  case "$(yq --version 2>&1)" in
    *mikefarah*) : ;;
    *) die "this script needs mikefarah/yq v4 (found: $(yq --version 2>&1))" ;;
  esac
}

# ── config resolution ────────────────────────────────────────────────────────
resolve_defaults() {
  [ -f "$STACK_FILE" ] || die "config not found: $STACK_FILE"
  [ -n "$TARGET" ]  || TARGET="$(qs '.defaults.target')"
  [ -n "$PROFILE" ] || PROFILE="$(qs '.defaults.profile')"

  [ "$(qs ".targets.\"$TARGET\" // \"\"")" != "" ] \
    || die "unknown target '$TARGET'. Available: $(q '.targets | keys | join(", ")')"
  [ "$(qs ".profiles.\"$PROFILE\" // \"\"")" != "" ] \
    || die "unknown profile '$PROFILE'. Available: $(q '.profiles | keys | join(", ")')"

  if [ "$(qs ".targets.\"$TARGET\".enabled")" = "false" ]; then
    die "target '$TARGET' is declared but not implemented yet (enabled: false)"
  fi

  # Resolve once, here in the parent shell. compute_* emit warnings, and they
  # are called from several process substitutions — memoizing keeps each
  # warning to a single line and prints it before any table output.
  RESOLVED_LAYERS="$(compute_layers)"
  RESOLVED_MODELS="$(compute_models)"
}

resolved_layers() { [ -n "${RESOLVED_LAYERS:-}" ] && printf '%s\n' "$RESOLVED_LAYERS"; return 0; }
resolved_models() { [ -n "${RESOLVED_MODELS:-}" ] && printf '%s\n' "$RESOLVED_MODELS"; return 0; }

# Layers the profile asks for, plus transitive `requires`, minus any layer
# globally switched off. Echoes one layer key per line.
compute_layers() {
  local wanted extra changed l req
  # space-separated so the `case " $wanted "` membership tests below work
  wanted="$(q ".profiles.\"$PROFILE\".layers[]" | tr '\n' ' ')"

  # close over `requires` until nothing new appears
  changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    for l in $wanted; do
      extra="$(qs ".layers.\"$l\".requires[]" 2>/dev/null || true)"
      for req in $extra; do
        [ -n "$req" ] || continue
        case " $wanted " in
          *" $req "*) : ;;
          *) wanted="$wanted $req"; changed=1 ;;
        esac
      done
    done
  done

  for l in $wanted; do
    if [ "$(qs ".layers.\"$l\".enabled")" = "true" ]; then
      printf '%s\n' "$l"
    else
      warn "layer '$l' is requested by profile '$PROFILE' but has enabled: false — skipping"
    fi
  done
}

# Compose profile names for layers that compose actually owns.
compose_profiles() {
  local l cp mb
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    mb="$(qs ".layers.\"$l\".managed_by")"
    [ "$mb" = "compose" ] || continue
    cp="$(qs ".layers.\"$l\".compose_profile")"
    [ -n "$cp" ] && printf '%s\n' "$cp"
  done < <(resolved_layers)
}

# Model aliases the profile exposes. Echoes one alias per line.
compute_models() {
  local list a
  if [ "$(qs ".profiles.\"$PROFILE\" | has(\"models\")")" = "true" ]; then
    list="$(q ".profiles.\"$PROFILE\".models[]")"
  else
    list="$(q '.models[] | select(.enabled == true) | .alias')"
  fi
  for a in $list; do
    if [ "$(qs ".models[] | select(.alias == \"$a\") | .enabled")" = "true" ]; then
      printf '%s\n' "$a"
    else
      warn "model '$a' is listed in profile '$PROFILE' but has enabled: false — skipping"
    fi
  done
}

model_field() { qs ".models[] | select(.alias == \"$1\") | $2"; }

# Highest `phase:` among the layers this profile brings up. Drives how far
# `doctor` looks when checking optional secrets.
profile_max_phase() {
  local l p max=1
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    p="$(qs ".layers.\"$l\".phase")"
    [ -n "$p" ] || continue
    [ "$p" -gt "$max" ] && max="$p"
  done < <(resolved_layers)
  printf '%s' "$max"
}

load_env() {
  local f
  f="$REPO_ROOT/$(qs '.secrets.file')"
  [ -f "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

target_host() {
  local h
  h="$(qs ".targets.\"$TARGET\".host")"
  if [ -z "$h" ] && [ "$(qs ".targets.\"$TARGET\".kind")" = "terraform" ]; then
    local d; d="$REPO_ROOT/$(qs ".targets.\"$TARGET\".dir")"
    if [ -d "$d" ]; then
      h="$(terraform -chdir="$d" output -raw public_ip 2>/dev/null || true)"
    fi
  fi
  printf '%s' "${h:-localhost}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  render — model catalog -> litellm_config.yaml + librechat.yaml
# ═════════════════════════════════════════════════════════════════════════════
render_litellm() {
  local out banner a model base key rpm tpm ctx ci co in_tok out_tok
  out="$REPO_ROOT/$(qs '.render.files.litellm')"
  banner="$(qs '.render.banner')"
  mkdir -p "$(dirname "$out")"

  {
    printf '# %s\n' "$banner"
    printf '# profile: %s\n\n' "$PROFILE"
    printf 'model_list:\n'

    while IFS= read -r a; do
      [ -n "$a" ] || continue
      model="$(model_field "$a" '.litellm_model')"
      base="$(model_field "$a" '.api_base_env')"
      key="$(model_field "$a" '.api_key_env')"
      rpm="$(model_field "$a" '.rate_limit.rpm')"
      tpm="$(model_field "$a" '.rate_limit.tpm')"
      ctx="$(model_field "$a" '.context_window')"
      ci="$(model_field "$a" '.cost_per_1k.input')"
      co="$(model_field "$a" '.cost_per_1k.output')"

      # stack.yaml carries USD per 1k tokens; LiteLLM wants per-token.
      in_tok="$(awk -v c="${ci:-0}" 'BEGIN{printf "%.12g", c/1000}')"
      out_tok="$(awk -v c="${co:-0}" 'BEGIN{printf "%.12g", c/1000}')"

      if [ -n "$key" ] && [ -z "${!key:-}" ]; then
        warn "model '$a' selected but \$$key is not set — requests to it will fail"
      fi

      printf '  - model_name: %s\n'      "$a"
      printf '    litellm_params:\n'
      printf '      model: %s\n'         "$model"
      [ -n "$base" ] && printf '      api_base: os.environ/%s\n' "$base"
      [ -n "$key" ]  && printf '      api_key: os.environ/%s\n'  "$key"
      [ -n "$rpm" ]  && printf '      rpm: %s\n' "$rpm"
      [ -n "$tpm" ]  && printf '      tpm: %s\n' "$tpm"
      printf '    model_info:\n'
      printf '      mode: chat\n'
      [ -n "$ctx" ] && printf '      max_input_tokens: %s\n' "$ctx"
      printf '      input_cost_per_token: %s\n'  "$in_tok"
      printf '      output_cost_per_token: %s\n' "$out_tok"
    done < <(resolved_models)

    # ── litellm_settings ──
    printf '\nlitellm_settings:\n'
    printf '  success_callback: [%s]\n' "$(q '.layers.gateway.options.callbacks.success | join(", ")')"
    printf '  failure_callback: [%s]\n' "$(q '.layers.gateway.options.callbacks.failure | join(", ")')"
    printf '  drop_params: %s\n'  "$(qs '.layers.gateway.options.drop_params')"
    printf '  num_retries: %s\n'  "$(qs '.layers.gateway.options.num_retries')"
    printf '  request_timeout: %s\n' "$(qs '.layers.gateway.options.request_timeout_s')"
    local budget
    budget="$(qs '.layers.gateway.options.budget.max_budget_usd')"
    [ -n "$budget" ] && printf '  max_budget: %s\n' "$budget"

    # ── router_settings — only emit fallbacks whose models are all present ──
    printf '\nrouter_settings:\n'
    printf '  routing_strategy: %s\n' "$(qs '.layers.gateway.options.routing.strategy')"
    local selected fb_from fb_to keep t
    selected=" $(resolved_models | tr '\n' ' ')"
    local fb_lines=""
    while IFS= read -r fb_from; do
      [ -n "$fb_from" ] || continue
      case "$selected" in *" $fb_from "*) : ;; *) continue ;; esac
      keep=""
      for t in $(q ".layers.gateway.options.routing.fallbacks[] | select(.from == \"$fb_from\") | .to[]"); do
        case "$selected" in *" $t "*) keep="$keep${keep:+, }$t" ;; esac
      done
      [ -n "$keep" ] && fb_lines="$fb_lines    - { \"$fb_from\": [$keep] }
"
    done < <(q '.layers.gateway.options.routing.fallbacks[].from')
    if [ -n "$fb_lines" ]; then
      printf '  fallbacks:\n'
      printf '%s' "$fb_lines"
    fi

    printf '\ngeneral_settings:\n'
    printf '  master_key: os.environ/%s\n' "$(qs '.layers.gateway.options.master_key_env')"
  } > "$out"

  ok "rendered $(printf '%s' "${out#"$REPO_ROOT/"}")"
}

render_librechat() {
  local out banner a label desc first
  out="$REPO_ROOT/$(qs '.render.files.librechat')"
  banner="$(qs '.render.banner')"
  mkdir -p "$(dirname "$out")"

  {
    printf '# %s\n' "$banner"
    printf '# profile: %s\n\n' "$PROFILE"
    printf 'version: 1.2.8\n'
    printf 'cache: true\n\n'
    printf 'endpoints:\n'
    printf '  custom:\n'
    printf '    - name: "%s"\n'  "$(qs '.layers.ui.options.endpoint_label')"
    printf '      apiKey: "${%s}"\n' "$(qs '.layers.gateway.options.master_key_env')"
    printf '      baseURL: "%s"\n' "$(qs '.layers.ui.options.gateway_internal_url')"
    printf '      models:\n'
    printf '        default:\n'
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      printf '          - "%s"\n' "$a"
    done < <(resolved_models)
    printf '        fetch: false\n'
    printf '      titleConvo: true\n'
    # Only auto-title with a model this profile actually exposes.
    local tm; tm="$(qs '.layers.ui.options.title_model')"
    case " $(resolved_models | tr '\n' ' ') " in
      *" $tm "*) printf '      titleModel: "%s"\n' "$tm" ;;
      *) first="$(resolved_models | head -1)"
         [ -n "$first" ] && printf '      titleModel: "%s"\n' "$first" ;;
    esac
    printf '      modelDisplayLabel: "%s"\n' "$(qs '.layers.ui.options.endpoint_label')"
    printf '      iconURL: ""\n'

    # Descriptions live in stack.yaml; keep them as comments so the single
    # source of truth stays readable from the rendered file.
    printf '\n# Model catalog (from stack.yaml):\n'
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      label="$(model_field "$a" '.ui.label')"
      desc="$(model_field "$a" '.ui.description')"
      printf '#   %-14s %s — %s\n' "$a" "$label" "$desc"
    done < <(resolved_models)
  } > "$out"

  ok "rendered $(printf '%s' "${out#"$REPO_ROOT/"}")"
}

cmd_render() {
  resolve_defaults; load_env
  info "Rendering configs  ${C_DIM}profile=$PROFILE${C_RST}"
  render_litellm
  render_librechat
}

# ═════════════════════════════════════════════════════════════════════════════
#  doctor — preflight
# ═════════════════════════════════════════════════════════════════════════════
cmd_doctor() {
  resolve_defaults; load_env
  local fail=0 kind s v l mb

  info "Config"
  ok "stack.yaml schema $(qs '.schema')  project=$(qs '.project.name')  env=$(qs '.project.environment')"
  ok "target=$TARGET  profile=$PROFILE"

  info "Tooling"
  ok "yq $(yq --version 2>&1 | awk '{print $NF}')"
  kind="$(qs ".targets.\"$TARGET\".kind")"
  case "$kind" in
    compose)
      if command -v docker >/dev/null 2>&1; then ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
      else bad "docker not found"; fail=1; fi
      if docker compose version >/dev/null 2>&1; then ok "docker compose $(docker compose version --short 2>/dev/null)"
      else bad "docker compose v2 not found"; fail=1; fi
      if docker info >/dev/null 2>&1; then ok "docker daemon reachable"
      else bad "docker daemon not running"; fail=1; fi
      ;;
    terraform)
      if command -v terraform >/dev/null 2>&1; then ok "terraform $(terraform version -json 2>/dev/null | yq -p=json '.terraform_version' 2>/dev/null || terraform version | head -1)"
      else bad "terraform not found"; fail=1; fi
      ;;
  esac

  local maxphase ph
  maxphase="$(profile_max_phase)"
  info "Secrets  ${C_DIM}($(qs '.secrets.file'), phases 1..$maxphase)${C_RST}"
  [ -f "$REPO_ROOT/$(qs '.secrets.file')" ] \
    || warn "$(qs '.secrets.file') not found — copy .env.example and fill it in"
  for s in $(q '.secrets.required[]'); do
    if [ -n "${!s:-}" ]; then ok "$s set"; else bad "$s missing (required)"; fail=1; fi
  done
  for ph in $(q '.secrets.optional | keys | .[]'); do
    if [ "$SHOW_ALL" -eq 0 ] && [ "$ph" -gt "$maxphase" ]; then continue; fi
    for s in $(q ".secrets.optional.\"$ph\"[]"); do
      if [ -n "${!s:-}" ]; then ok "$s set"
      else warn "$s unset (optional, phase $ph)"; fi
    done
  done

  info "Layers"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    mb="$(qs ".layers.\"$l\".managed_by")"
    ok "$(printf '%-14s' "$l") impl=$(qs ".layers.\"$l\".impl")  managed_by=$mb"
  done < <(resolved_layers)

  info "Models"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    v="$(model_field "$s" '.api_key_env')"
    if [ -z "$v" ] || [ -n "${!v:-}" ]; then
      ok "$(printf '%-14s' "$s") $(model_field "$s" '.tier')  $(model_field "$s" '.litellm_model')"
    else
      warn "$(printf '%-14s' "$s") $(model_field "$s" '.tier')  \$$v unset — will fail at request time"
    fi
  done < <(resolved_models)

  # vLLM lives outside compose; its endpoint must already exist.
  if resolved_layers | grep -qx serving; then
    info "Serving (external)"
    local ab; ab="$(qs '.layers.serving.options.api_base_env')"
    if [ -n "${!ab:-}" ]; then ok "$ab=${!ab}"
    else warn "$ab unset — Phase 3 work. Deploy a pod (runpod/deploy_vllm.md) or use --profile phase-1"; fi
  fi

  say ""
  if [ "$fail" -eq 0 ]; then say "${C_GRN}${C_B}preflight passed${C_RST}"
  else die "preflight failed — fix the ✗ items above"; fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  config / models — introspection
# ═════════════════════════════════════════════════════════════════════════════
cmd_config() {
  resolve_defaults
  say "${C_B}project${C_RST}  $(qs '.project.name') ($(qs '.project.environment'))"
  say "${C_B}target${C_RST}   $TARGET — $(qs ".targets.\"$TARGET\".description")"
  say "${C_B}profile${C_RST}  $PROFILE — $(qs ".profiles.\"$PROFILE\".description")"
  say ""
  say "${C_B}layers${C_RST}"
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    printf '  %-14s %-12s %-10s %s\n' "$l" "$(qs ".layers.\"$l\".impl")" \
      "$(qs ".layers.\"$l\".managed_by")" "$(qs ".layers.\"$l\".compose_profile")"
  done < <(resolved_layers)
  say ""
  say "${C_B}compose profiles${C_RST}  $(compose_profiles | tr '\n' ' ')"
  say "${C_B}models${C_RST}            $(resolved_models | tr '\n' ' ')"
}

# ═════════════════════════════════════════════════════════════════════════════
#  secrets — credentials.yaml is the human source; .env is generated from it
# ═════════════════════════════════════════════════════════════════════════════
CRED_FILE_REL="secrets/credentials.yaml"
CRED_FILE="$REPO_ROOT/$CRED_FILE_REL"

cq() { local v; v="$(yq "$1" "$CRED_FILE")"; [ "$v" = "null" ] && v=""; printf '%s' "$v"; }

require_credentials() {
  [ -f "$CRED_FILE" ] || die "$CRED_FILE_REL not found.
  cp secrets/credentials.example.yaml $CRED_FILE_REL && \$EDITOR $CRED_FILE_REL"
}

# credentials.yaml -> .env
cmd_secrets_write() {
  require_credentials
  local envf dest n i count name env val ph blank=0
  envf="$REPO_ROOT/$(qs '.secrets.file')"
  # NB: "0" is non-empty, so ${DRY_RUN:+...} would always fire — test properly.
  dest="$envf"
  [ "$DRY_RUN" -eq 1 ] && dest=/dev/stdout

  if [ -f "$envf" ] && [ "$DRY_RUN" -eq 0 ]; then
    cp "$envf" "$envf.bak"
    warn "existing .env backed up to .env.bak"
  fi

  count="$(cq '.credentials | length')"
  {
    printf '# GENERATED by `stack.sh secrets write` from %s — DO NOT EDIT.\n' "$CRED_FILE_REL"
    printf '# Edit %s, then re-run. Reviewed: %s\n\n' "$CRED_FILE_REL" "$(cq '.meta.last_reviewed')"
    i=0
    while [ "$i" -lt "$count" ]; do
      env="$(cq ".credentials[$i].env")"
      val="$(cq ".credentials[$i].value")"
      name="$(cq ".credentials[$i].name")"
      ph="$(cq ".credentials[$i].phase")"
      i=$((i + 1))
      [ -n "$env" ] || continue
      printf '# %s (phase %s)\n' "$name" "$ph"
      printf '%s=%s\n' "$env" "$val"
    done
  } > "$dest"

  [ "$DRY_RUN" -eq 1 ] && return 0

  chmod 600 "$envf"
  ok "wrote $(printf '%s' "${envf#"$REPO_ROOT/"}") (mode 600) from $CRED_FILE_REL"

  i=0
  while [ "$i" -lt "$count" ]; do
    env="$(cq ".credentials[$i].env")"; val="$(cq ".credentials[$i].value")"
    i=$((i + 1))
    [ -n "$env" ] && [ -z "$val" ] && blank=$((blank + 1))
  done
  [ "$blank" -gt 0 ] && warn "$blank of $count credentials still blank — run: ./scripts/stack.sh doctor"
  return 0
}

# Print a generated value for every credential that declares `generate:`.
cmd_secrets_gen() {
  require_credentials
  local i count env g
  count="$(cq '.credentials | length')"
  info "Suggested values for self-generated credentials"
  say "${C_DIM}Paste into $CRED_FILE_REL, then: ./scripts/stack.sh secrets write${C_RST}"
  say ""
  i=0
  while [ "$i" -lt "$count" ]; do
    env="$(cq ".credentials[$i].env")"
    g="$(cq ".credentials[$i].generate")"
    i=$((i + 1))
    [ -n "$g" ] || continue
    printf '  %-34s %s\n' "$env" "$(eval "$g" 2>/dev/null || echo '<generate manually>')"
  done
}

# Verify nothing sensitive can reach git, Docker, or an AI tool's index.
cmd_secrets_audit() {
  local fail=0 f p
  local guarded=".env $CRED_FILE_REL"

  info "Ignore coverage"
  for p in $guarded; do
    if git -C "$REPO_ROOT" check-ignore -q "$p" 2>/dev/null; then ok "git ignores $p"
    else bad "git does NOT ignore $p"; fail=1; fi
  done

  for f in .dockerignore .cursorignore .aiignore .aiexclude .codeiumignore \
           .aiderignore .continueignore .geminiignore .codexignore; do
    if [ ! -f "$REPO_ROOT/$f" ]; then
      warn "$f missing"
    elif grep -qE '^\s*secrets/' "$REPO_ROOT/$f" && grep -qE '^\s*\.env\s*$' "$REPO_ROOT/$f"; then
      ok "$f covers secrets/ and .env"
    else
      bad "$f does not cover both secrets/ and .env"; fail=1
    fi
  done

  if [ -f "$REPO_ROOT/.claude/settings.json" ] \
     && grep -q 'Read(./secrets/\*\*)' "$REPO_ROOT/.claude/settings.json"; then
    ok ".claude/settings.json denies Read on secrets/"
  else
    bad ".claude/settings.json missing a deny rule for secrets/"; fail=1
  fi

  info "Nothing sensitive tracked"
  for p in $guarded; do
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
      bad "$p is TRACKED in the index — git rm --cached '$p'"; fail=1
    else ok "$p not in the index"; fi
  done

  # A file can be ignored today and still be sitting in history.
  for p in $guarded; do
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1 \
       && git -C "$REPO_ROOT" log --all --pretty=format: --name-only 2>/dev/null | grep -qxF "$p"; then
      bad "$p appears in git HISTORY — revoke those credentials at the provider"; fail=1
    else ok "$p absent from history"; fi
  done

  info "Committed template is value-free"
  if [ -f "$REPO_ROOT/secrets/credentials.example.yaml" ]; then
    # every `value:` in the template must be empty or a non-secret default
    if yq -e '[.credentials[].value] | map(select(. != "" and . != "minio" and . != "ap-northeast-2")) | length == 0' \
         "$REPO_ROOT/secrets/credentials.example.yaml" >/dev/null 2>&1; then
      ok "credentials.example.yaml has no real values"
    else
      bad "credentials.example.yaml contains a non-empty value — scrub it"; fail=1
    fi
  fi

  say ""
  if [ "$fail" -eq 0 ]; then say "${C_GRN}${C_B}secrets audit passed${C_RST}"
  else die "secrets audit FAILED — do not commit until the ✗ items are fixed"; fi
}

cmd_secrets() {
  case "${SECRETS_SUB:-}" in
    write) cmd_secrets_write ;;
    gen)   cmd_secrets_gen ;;
    audit) cmd_secrets_audit ;;
    *) die "usage: ./scripts/stack.sh secrets <write|gen|audit>" ;;
  esac
}

cmd_phases() {
  local cur n name st scope mark
  cur="$(qs '.phases.current')"
  say "${C_B}build-out phases${C_RST}  ${C_DIM}(current: $cur)${C_RST}"
  say ""
  for n in $(q '.phases | keys | .[] | select(. != "current")'); do
    name="$(qs ".phases.\"$n\".name")"
    st="$(qs ".phases.\"$n\".status")"
    scope="$(qs ".phases.\"$n\".scope")"
    if [ "$n" = "$cur" ]; then mark="${C_GRN}▶${C_RST}"; else mark=" "; fi
    printf '%s %sPhase %s — %s%s  %s[%s]%s\n' "$mark" "$C_B" "$n" "$name" "$C_RST" "$C_DIM" "$st" "$C_RST"
    printf '    %s\n' "$scope"
    printf '    %slayers:%s %s   %smodels:%s %s\n' \
      "$C_DIM" "$C_RST" "$(q ".phases.\"$n\".adds_layers | join(\", \")")" \
      "$C_DIM" "$C_RST" "$(q ".phases.\"$n\".adds_models | join(\", \")")"
    printf '    %sprofile:%s ./scripts/stack.sh up --profile phase-%s\n\n' "$C_DIM" "$C_RST" "$n"
  done
}

cmd_models() {
  resolve_defaults
  printf '%-15s %-12s %-38s %-10s %s\n' ALIAS TIER LITELLM_MODEL IN/1k OUT/1k
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%-15s %-12s %-38s %-10s %s\n' "$a" \
      "$(model_field "$a" '.tier')" "$(model_field "$a" '.litellm_model')" \
      "$(model_field "$a" '.cost_per_1k.input')" "$(model_field "$a" '.cost_per_1k.output')"
  done < <(resolved_models)
}

# ═════════════════════════════════════════════════════════════════════════════
#  up / down / status / logs
# ═════════════════════════════════════════════════════════════════════════════
# Must be called from the parent shell: `die` inside compose_args would only
# exit the command-substitution subshell and we would fall through to running
# `docker compose` with no -f, picking up whatever is in the cwd.
assert_compose_file() {
  local cf
  cf="$REPO_ROOT/$(qs ".targets.\"$TARGET\".compose_file")"
  [ -f "$cf" ] || die "compose file not found: ${cf#"$REPO_ROOT/"} — not scaffolded yet (Phase 1)"
}

compose_args() {
  # echoes the shared `docker compose` argument list, one per line
  local cf ef p
  cf="$REPO_ROOT/$(qs ".targets.\"$TARGET\".compose_file")"
  ef="$REPO_ROOT/$(qs ".targets.\"$TARGET\".env_file")"
  printf '%s\n' -f "$cf" -p "$(qs '.project.slug')"
  [ -f "$ef" ] && printf '%s\n' --env-file "$ef"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' --profile "$p"
  done < <(compose_profiles)
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then say "${C_DIM}\$ $*${C_RST}"; else "$@"; fi
}

cmd_up() {
  resolve_defaults; load_env
  local kind; kind="$(qs ".targets.\"$TARGET\".kind")"
  [ "$kind" = "compose" ] && assert_compose_file
  info "Bringing up  ${C_B}$TARGET${C_RST}  ${C_DIM}profile=$PROFILE${C_RST}"
  [ "$DO_RENDER" -eq 1 ] && { render_litellm; render_librechat; }

  case "$kind" in
    compose)
      local args=()
      while IFS= read -r a; do args+=("$a"); done < <(compose_args)
      run docker compose ${args[@]+"${args[@]}"} up -d
      ;;
    terraform)
      local d; d="$REPO_ROOT/$(qs ".targets.\"$TARGET\".dir")"
      [ -d "$d" ] || die "terraform dir not found: ${d#"$REPO_ROOT/"} (not scaffolded yet)"
      local tfargs=() k
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        tfargs+=("-var=$k=$(qs ".targets.\"$TARGET\".vars.\"$k\"")")
      done < <(q ".targets.\"$TARGET\".vars | keys | .[]")
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        tfargs+=("-var=$k")
      done < <(printf '%s' "$TF_VARS")
      run terraform -chdir="$d" init -input=false
      run terraform -chdir="$d" apply -input=false ${tfargs[@]+"${tfargs[@]}"}
      ;;
    *) die "target kind '$kind' is not supported yet" ;;
  esac

  [ "$DRY_RUN" -eq 1 ] && return 0
  say ""
  cmd_urls
  say ""
  say "${C_DIM}next:${C_RST} ./scripts/stack.sh status"
}

cmd_down() {
  resolve_defaults; load_env
  local kind; kind="$(qs ".targets.\"$TARGET\".kind")"
  case "$kind" in
    compose)
      assert_compose_file
      local args=()
      while IFS= read -r a; do args+=("$a"); done < <(compose_args)
      if [ "$PURGE" -eq 1 ]; then run docker compose ${args[@]+"${args[@]}"} down --volumes --remove-orphans
      else run docker compose ${args[@]+"${args[@]}"} down --remove-orphans; fi
      ;;
    terraform)
      local d; d="$REPO_ROOT/$(qs ".targets.\"$TARGET\".dir")"
      run terraform -chdir="$d" destroy -input=false
      warn "RunPod pods are billed separately — stop them in the RunPod console"
      ;;
  esac
}

cmd_urls() {
  resolve_defaults
  local host l port
  host="$(target_host)"
  say "${C_B}endpoints${C_RST}"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    port="$(qs ".layers.\"$l\".port")"
    [ -n "$port" ] || continue
    if [ "$(qs ".layers.\"$l\".managed_by")" = "compose" ]; then
      printf '  %-14s http://%s:%s\n' "$(qs ".layers.\"$l\".impl")" "$host" "$port"
    fi
  done < <(resolved_layers)
}

# Substitute {{host}} and {{ENV_VAR}} placeholders in a health-check URL.
expand_url() {
  local url="$1" host="$2" name val
  url="${url//\{\{host\}\}/$host}"
  while :; do
    case "$url" in
      *'{{'*'}}'*)
        name="${url#*\{\{}"; name="${name%%\}\}*}"
        val="${!name:-}"
        url="${url//\{\{$name\}\}/$val}"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$url"
}

cmd_status() {
  resolve_defaults; load_env
  local host to n lyr url code active
  host="$(target_host)"
  to="$(qs '.health.timeout_s')"
  active=" $(resolved_layers | tr '\n' ' ') "
  info "Health  ${C_DIM}host=$host${C_RST}"

  local i count
  count="$(q '.health.checks | length')"
  i=0
  while [ "$i" -lt "$count" ]; do
    n="$(qs ".health.checks[$i].name")"
    lyr="$(qs ".health.checks[$i].layer")"
    url="$(qs ".health.checks[$i].url")"
    i=$((i + 1))
    case "$active" in *" $lyr "*) : ;; *) continue ;; esac
    url="$(expand_url "$url" "$host")"
    case "$url" in
      *'{{'*|'/'*|'') warn "$(printf '%-12s' "$n") endpoint unknown (unresolved placeholder)"; continue ;;
    esac
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${to:-5}" "$url" 2>/dev/null || true)"
    case "$code" in
      2*|3*) ok   "$(printf '%-12s' "$n") $code  $url" ;;
      *)     bad  "$(printf '%-12s' "$n") ${code:-no-response}  $url" ;;
    esac
  done
}

cmd_logs() {
  resolve_defaults; load_env
  assert_compose_file
  local args=()
  while IFS= read -r a; do args+=("$a"); done < <(compose_args)
  docker compose ${args[@]+"${args[@]}"} logs -f --tail=100 ${EXTRA_ARGS:+$EXTRA_ARGS}
}

# ═════════════════════════════════════════════════════════════════════════════
usage() {
  cat <<EOF
${C_B}stack.sh${C_RST} — Sovereign AI Stack control plane

${C_B}USAGE${C_RST}
  ./scripts/stack.sh <command> [flags]

${C_B}COMMANDS${C_RST}
  doctor      Preflight: tooling, secrets, layers, models
  secrets write   Generate .env from secrets/credentials.yaml
  secrets gen     Print values for self-generated credentials
  secrets audit   Verify secrets cannot reach git / Docker / AI tool indexes
  phases      Show the build-out phases and which one is current
  config      Show the resolved stack for the selected target/profile
  models      Table of the models this profile exposes
  render      Regenerate litellm_config.yaml and librechat.yaml
  up          Render, then deploy to the selected target
  down        Tear the selected target down
  status      Curl every health check for the active layers
  urls        Print the endpoint list
  logs        Follow compose logs

${C_B}FLAGS${C_RST}
  -t, --target <name>    Deployment target (default: stack.yaml defaults.target)
  -p, --profile <name>   Stack profile (default: stack.yaml defaults.profile)
      --tf-var k=v       Extra terraform variable (repeatable)
      --all              doctor: check secrets for every phase, not just active
      --no-render        Skip config rendering on \`up\`
      --purge            On \`down\`, also delete volumes (DESTRUCTIVE)
  -n, --dry-run          Print the commands instead of running them
  -f, --file <path>      Alternate stack.yaml
  -h, --help             This message

${C_B}EXAMPLES${C_RST}
  ./scripts/stack.sh doctor --profile phase-1
  ./scripts/stack.sh up --target docker --profile full
  ./scripts/stack.sh up --target aws-ec2 --tf-var key_name=kp --tf-var allowed_cidr=1.2.3.4/32
  ./scripts/stack.sh down --purge
EOF
}

main() {
  local cmd="${1:-help}"; shift || true

  # `secrets` takes a bare subcommand before any flags.
  if [ "$cmd" = "secrets" ]; then
    case "${1:-}" in
      write|gen|audit) SECRETS_SUB="$1"; shift ;;
      *) die "usage: ./scripts/stack.sh secrets <write|gen|audit>" ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -t|--target)  TARGET="$2"; shift 2 ;;
      -p|--profile) PROFILE="$2"; shift 2 ;;
      -f|--file)    STACK_FILE="$2"; shift 2 ;;
      --tf-var)     TF_VARS="$TF_VARS$2
"; shift 2 ;;
      --all)        SHOW_ALL=1; shift ;;
      --no-render)  DO_RENDER=0; shift ;;
      --purge)      PURGE=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  case "$cmd" in
    help|-h|--help) usage ;;
    doctor)  require_yq; cmd_doctor ;;
    secrets) require_yq; cmd_secrets ;;
    phases)  require_yq; cmd_phases ;;
    config) require_yq; cmd_config ;;
    models) require_yq; cmd_models ;;
    render) require_yq; cmd_render ;;
    up)     require_yq; cmd_up ;;
    down)   require_yq; cmd_down ;;
    status) require_yq; cmd_status ;;
    urls)   require_yq; cmd_urls ;;
    logs)   require_yq; cmd_logs ;;
    *) die "unknown command: $cmd  (try: ./scripts/stack.sh help)" ;;
  esac
}

main "$@"
