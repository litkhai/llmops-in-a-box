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
SECRETS_PHASE=""
SECRETS_ONLY=""
SECRETS_FORCE=0

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
  local f cf count i env val line key
  f="$REPO_ROOT/$(qs '.secrets.file')"
  cf="$REPO_ROOT/secrets/credentials.yaml"

  # Prefer the structured credential store. `export "$name=$value"` assigns a
  # literal value; unlike sourcing .env it cannot execute shell syntax embedded
  # in a credential.
  if [ -f "$cf" ]; then
    count="$(yq '.credentials | length' "$cf")"
    i=0
    while [ "$i" -lt "$count" ]; do
      env="$(yq -r ".credentials[$i].env // \"\"" "$cf")"
      val="$(yq -r ".credentials[$i].value // \"\"" "$cf")"
      i=$((i + 1))
      case "$env" in
        ''|*[!A-Z0-9_]*) continue ;;
      esac
      export "$env=$val"
    done
    return 0
  fi

  # Backward-compatible reader for an existing .env. This deliberately does
  # not use `source` or `eval`; only NAME=VALUE records are accepted.
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    [ "$key" != "$line" ] || continue
    case "$key" in ''|*[!A-Z0-9_]*) continue ;; esac
    val="${line#*=}"
    case "$val" in
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
    esac
    export "$key=$val"
  done < "$f"
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
    # LiteLLM rejects max_budget without budget_duration and refuses to start:
    #   Exception: budget_duration not set on Proxy. budget_duration is
    #   required to use max_budget.
    # stack.yaml carries both (max_budget_usd + duration); only the first was
    # being emitted, so the gateway crash-looped on exit code 3 as soon as the
    # compose stack actually ran it. Emit the pair, or neither.
    local budget budget_duration
    budget="$(qs '.layers.gateway.options.budget.max_budget_usd')"
    budget_duration="$(qs '.layers.gateway.options.budget.duration')"
    if [ -n "$budget" ] && [ -n "$budget_duration" ]; then
      printf '  max_budget: %s\n' "$budget"
      printf '  budget_duration: %s\n' "$budget_duration"
    elif [ -n "$budget" ]; then
      warn "budget.max_budget_usd is set but budget.duration is not — omitting both, LiteLLM requires the pair"
    fi
    local lr_enabled
    lr_enabled="$(qs '.layers.gateway.options.language_routing.enabled')"
    if [ "$lr_enabled" = "true" ]; then
      printf '  custom_callbacks: [/app/callbacks.py]\n'
    fi

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
CRED_TEMPLATE_REL="secrets/credentials.example.yaml"
CRED_TEMPLATE="$REPO_ROOT/$CRED_TEMPLATE_REL"

cq() { local v; v="$(yq "$1" "$CRED_FILE")"; [ "$v" = "null" ] && v=""; printf '%s' "$v"; }

require_credentials() {
  [ -f "$CRED_FILE" ] || die "$CRED_FILE_REL not found.
  Run: ./scripts/stack.sh secrets init"
  [ ! -L "$CRED_FILE" ] || die "$CRED_FILE_REL must not be a symlink"
}

credential_read_file() {
  if [ -f "$CRED_FILE" ]; then printf '%s' "$CRED_FILE"
  else printf '%s' "$CRED_TEMPLATE"; fi
}

cmd_secrets_init() {
  local added
  [ -f "$CRED_TEMPLATE" ] || die "credential template not found: $CRED_TEMPLATE_REL"
  [ ! -L "$CRED_FILE" ] || die "$CRED_FILE_REL must not be a symlink"
  if [ -f "$CRED_FILE" ]; then
    chmod 600 "$CRED_FILE"
    ok "$CRED_FILE_REL already exists (mode 600 enforced)"
    added="$(sync_credential_inventory)"
    [ "$added" -eq 0 ] || ok "added $added new credential definition(s) from the template"
    return 0
  fi

  umask 077
  cp "$CRED_TEMPLATE" "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  ok "created $CRED_FILE_REL (mode 600)"
  say "${C_DIM}next:${C_RST} ./scripts/stack.sh secrets setup"
}

sync_credential_inventory() {
  local dir tmp added
  if ! added="$(
    CRED_TEMPLATE_PATH="$CRED_TEMPLATE" CRED_PRIVATE_PATH="$CRED_FILE" \
    yq -n -r '
      load(strenv(CRED_TEMPLATE_PATH)) as $template |
      load(strenv(CRED_PRIVATE_PATH)) as $private |
      ($private.credentials | map(.env)) as $existing |
      [$template.credentials[] | select(.env as $env | ($existing | contains([$env])) == false)] |
      length
    '
  )"; then
    die "failed to compare $CRED_FILE_REL with the credential template"
  fi
  case "$added" in ''|*[!0-9]*) die "credential template comparison returned an invalid count" ;; esac
  if [ "$added" -eq 0 ]; then
    printf '0'
    return 0
  fi

  dir="$(dirname "$CRED_FILE")"
  umask 077
  tmp="$(mktemp "$dir/.credentials.XXXXXX")"
  if ! CRED_TEMPLATE_PATH="$CRED_TEMPLATE" CRED_PRIVATE_PATH="$CRED_FILE" \
    yq -n '
      load(strenv(CRED_TEMPLATE_PATH)) as $template |
      load(strenv(CRED_PRIVATE_PATH)) as $private |
      ($private.credentials | map(.env)) as $existing |
      $private |
      .credentials += [
        $template.credentials[] |
        select(.env as $env | ($existing | contains([$env])) == false)
      ]
    ' > "$tmp"; then
    rm -f "$tmp"
    die "failed to synchronize $CRED_FILE_REL; the original was preserved"
  fi
  yq -e '.credentials | type == "!!seq"' "$tmp" >/dev/null \
    || { rm -f "$tmp"; die "credential synchronization produced invalid YAML; the original was preserved"; }
  chmod 600 "$tmp"
  mv "$tmp" "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  printf '%s' "$added"
}

validate_phase() {
  case "$1" in 1|2|3|4|5) return 0 ;; *) return 1 ;; esac
}

select_secrets_phase() {
  local p n name f
  if [ -n "$SECRETS_PHASE" ]; then
    validate_phase "$SECRETS_PHASE" || die "--phase must be 1, 2, 3, 4, or 5"
    return 0
  fi
  [ "$SHOW_ALL" -eq 0 ] || return 0
  if [ -n "$SECRETS_ONLY" ]; then
    f="$(credential_read_file)"
    SECRETS_PHASE="$(yq -r ".credentials[] | select(.env == \"$SECRETS_ONLY\") | .phase" "$f")"
    [ -n "$SECRETS_PHASE" ] || die "unknown credential '$SECRETS_ONLY'"
    validate_phase "$SECRETS_PHASE" || die "$SECRETS_ONLY has an invalid phase"
    return 0
  fi
  [ -t 0 ] || die "select a phase with --phase 1..5 (or use --all)"

  say "${C_B}credential phases${C_RST}"
  for p in 1 2 3 4 5; do
    name="$(qs ".phases.\"$p\".name")"
    [ -n "$name" ] || name="Phase $p"
    n="$(yq "[.credentials[] | select(.phase == $p)] | length" "$CRED_TEMPLATE")"
    printf '  %s) %-28s %s credentials\n' "$p" "$name" "$n"
  done
  printf 'Select phase [1-5]: ' >&2
  IFS= read -r SECRETS_PHASE
  validate_phase "$SECRETS_PHASE" || die "invalid phase '$SECRETS_PHASE'"
}

credential_in_scope() {
  local phase="$1"
  [ "$SHOW_ALL" -eq 1 ] && return 0
  [ -z "$SECRETS_PHASE" ] && return 0
  [ "$phase" = "$SECRETS_PHASE" ]
}

credential_generator_spec() {
  local env="$1" current="$2"
  if [ -n "$current" ]; then printf '%s' "$current"
  else yq -r ".credentials[] | select(.env == \"$env\") | .generate // \"\"" "$CRED_TEMPLATE"; fi
}

credential_generator_id() {
  # Accept the original exact commands for existing private inventories, but
  # never eval them. New templates use the stable IDs on the left.
  case "$1" in
    sk-hex-24|"openssl rand -hex 24 | sed 's/^/sk-/'") printf 'sk-hex-24' ;;
    lf-pk-hex-16)                                      printf 'lf-pk-hex-16' ;;
    lf-sk-hex-24)                                      printf 'lf-sk-hex-24' ;;
    hex-32|"openssl rand -hex 32")                     printf 'hex-32' ;;
    base64-32|"openssl rand -base64 32")               printf 'base64-32' ;;
    hex-16|"openssl rand -hex 16")                     printf 'hex-16' ;;
    hex-24|"openssl rand -hex 24")                     printf 'hex-24' ;;
    identifier-12)                                     printf 'identifier-12' ;;
    '')                                                return 1 ;;
    *)                                                 return 2 ;;
  esac
}

generate_credential_value() {
  local id="$1" r
  GENERATED_VALUE=""
  command -v openssl >/dev/null 2>&1 || {
    VALIDATION_MESSAGE="openssl is required for local generation"
    return 1
  }
  case "$id" in
    sk-hex-24)    r="$(openssl rand -hex 24)" && GENERATED_VALUE="sk-$r" ;;
    lf-pk-hex-16) r="$(openssl rand -hex 16)" && GENERATED_VALUE="lf_pk_$r" ;;
    lf-sk-hex-24) r="$(openssl rand -hex 24)" && GENERATED_VALUE="lf_sk_$r" ;;
    hex-32)       GENERATED_VALUE="$(openssl rand -hex 32)" ;;
    base64-32)    GENERATED_VALUE="$(openssl rand -base64 32 | tr -d '\r\n')" ;;
    hex-16)       GENERATED_VALUE="$(openssl rand -hex 16)" ;;
    hex-24)       GENERATED_VALUE="$(openssl rand -hex 24)" ;;
    identifier-12) r="$(openssl rand -hex 6)" && GENERATED_VALUE="minio-$r" ;;
    *) VALIDATION_MESSAGE="unsupported generator '$id'"; return 1 ;;
  esac
  [ -n "$GENERATED_VALUE" ]
}

validate_credential_value() {
  local env="$1" val="$2" prefix ip a b c d extra octet
  VALIDATION_MESSAGE=""
  if [ -z "$val" ]; then VALIDATION_MESSAGE="missing"; return 2; fi
  case "$val" in
    *$'\n'*|*$'\r'*) VALIDATION_MESSAGE="must be a single line"; return 1 ;;
  esac
  case "$env" in
    OPENAI_API_KEY|ANTHROPIC_API_KEY|LANGFUSE_PUBLIC_KEY|LANGFUSE_SECRET_KEY|\
    LANGFUSE_EE_LICENSE_KEY|\
    RUNPOD_API_KEY|VLLM_API_KEY|HF_TOKEN|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY)
      case "$val" in *[[:space:]]*) VALIDATION_MESSAGE="must not contain whitespace"; return 1 ;; esac ;;
  esac

  case "$env" in
    OPENAI_API_KEY)
      case "$val" in sk-?*) [ "${#val}" -ge 20 ] || { VALIDATION_MESSAGE="expected an OpenAI sk- key"; return 1; } ;;
        *) VALIDATION_MESSAGE="expected prefix sk-"; return 1 ;; esac ;;
    ANTHROPIC_API_KEY)
      case "$val" in sk-ant-?*) [ "${#val}" -ge 20 ] \
        || { VALIDATION_MESSAGE="expected an Anthropic sk-ant- key"; return 1; } ;;
        *) VALIDATION_MESSAGE="expected prefix sk-ant-"; return 1 ;; esac ;;
    LITELLM_MASTER_KEY)
      case "$val" in sk-?*) [ "${#val}" -ge 20 ] || { VALIDATION_MESSAGE="must be at least 20 characters"; return 1; } ;;
        *) VALIDATION_MESSAGE="expected prefix sk-"; return 1 ;; esac ;;
    LITELLM_SALT_KEY)
      [ "${#val}" -ge 32 ] || { VALIDATION_MESSAGE="must be at least 32 characters"; return 1; } ;;
    LANGFUSE_ENCRYPTION_KEY|LIBRECHAT_CREDS_KEY|LIBRECHAT_JWT_SECRET|LIBRECHAT_JWT_REFRESH_SECRET)
      case "$val" in *[!0-9a-fA-F]*|'') VALIDATION_MESSAGE="expected 64 hexadecimal characters"; return 1 ;; esac
      [ "${#val}" -eq 64 ] || { VALIDATION_MESSAGE="expected 64 hexadecimal characters"; return 1; } ;;
    LIBRECHAT_CREDS_IV)
      case "$val" in *[!0-9a-fA-F]*|'') VALIDATION_MESSAGE="expected 32 hexadecimal characters"; return 1 ;; esac
      [ "${#val}" -eq 32 ] || { VALIDATION_MESSAGE="expected 32 hexadecimal characters"; return 1; } ;;
    LANGFUSE_PUBLIC_KEY)
      case "$val" in lf_pk_?*|pk-lf-?*) [ "${#val}" -ge 12 ] \
        || { VALIDATION_MESSAGE="expected a Langfuse public key"; return 1; } ;;
        *) VALIDATION_MESSAGE="expected prefix lf_pk_"; return 1 ;; esac ;;
    LANGFUSE_SECRET_KEY)
      case "$val" in lf_sk_?*|sk-lf-?*) [ "${#val}" -ge 12 ] \
        || { VALIDATION_MESSAGE="expected a Langfuse secret key"; return 1; } ;;
        *) VALIDATION_MESSAGE="expected prefix lf_sk_"; return 1 ;; esac ;;
    VLLM_API_BASE)
      case "$val" in http://*/v1|https://*/v1) : ;; *) VALIDATION_MESSAGE="expected an http(s) URL ending in /v1"; return 1 ;; esac ;;
    MCP_CLICKHOUSE_URL)
      case "$val" in http://*|https://*) : ;; *) VALIDATION_MESSAGE="expected an http(s) URL"; return 1 ;; esac ;;
    CLICKHOUSE_CLOUD_HOST)
      case "$val" in *://*|*/*|*[[:space:]]*) VALIDATION_MESSAGE="expected a hostname without scheme or path"; return 1 ;; esac ;;
    AWS_ACCESS_KEY_ID)
      case "$val" in AKIA????????????????|ASIA????????????????) : ;;
        *) VALIDATION_MESSAGE="expected a 20-character AKIA/ASIA access key ID"; return 1 ;; esac ;;
    AWS_SECRET_ACCESS_KEY)
      [ "${#val}" -ge 40 ] || { VALIDATION_MESSAGE="expected at least 40 characters"; return 1; } ;;
    AWS_REGION)
      case "$val" in [a-z][a-z]-[a-z0-9-]*-[0-9]) : ;; *) VALIDATION_MESSAGE="expected a region such as ap-northeast-2"; return 1 ;; esac ;;
    AWS_ALLOWED_CIDR)
      [ "$val" != "0.0.0.0/0" ] || { VALIDATION_MESSAGE="0.0.0.0/0 is forbidden"; return 1; }
      case "$val" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*/[0-9]*)
          prefix="${val##*/}"; ip="${val%/*}" ;;
        *) VALIDATION_MESSAGE="expected IPv4 CIDR, preferably your-ip/32"; return 1 ;;
      esac
      case "$prefix" in ''|*[!0-9]*) VALIDATION_MESSAGE="CIDR prefix must be numeric"; return 1 ;; esac
      [ "$prefix" -ge 0 ] 2>/dev/null && [ "$prefix" -le 32 ] 2>/dev/null \
        || { VALIDATION_MESSAGE="CIDR prefix must be 0..32"; return 1; }
      IFS=. read -r a b c d extra <<< "$ip"
      [ -z "$extra" ] || { VALIDATION_MESSAGE="expected exactly four IPv4 octets"; return 1; }
      for octet in "$a" "$b" "$c" "$d"; do
        case "$octet" in ''|*[!0-9]*) VALIDATION_MESSAGE="IPv4 octets must be numeric"; return 1 ;; esac
        [ "$octet" -le 255 ] 2>/dev/null \
          || { VALIDATION_MESSAGE="IPv4 octets must be 0..255"; return 1; }
      done ;;
    MINIO_ROOT_PASSWORD|ARTIFACT_MINIO_ROOT_PASSWORD|LANGFUSE_INIT_USER_PASSWORD|UI_PASSWORD)
      [ "${#val}" -ge 8 ] || { VALIDATION_MESSAGE="must be at least 8 characters"; return 1; } ;;
    MINIO_ROOT_USER|ARTIFACT_MINIO_ROOT_USER|CLICKHOUSE_CLOUD_USER|\
    CLICKHOUSE_USER|POSTGRES_USER|LANGFUSE_INIT_USER_NAME|UI_USERNAME)
      case "$val" in *[[:space:]]*) VALIDATION_MESSAGE="must not contain whitespace"; return 1 ;; esac ;;
    LANGFUSE_INIT_USER_EMAIL)
      case "$val" in
        ?*@?*.?*) : ;;
        *) VALIDATION_MESSAGE="expected an email address"; return 1 ;;
      esac ;;
  esac
  VALIDATION_MESSAGE="valid format"
  return 0
}

persist_credential_value() {
  local env="$1" val="$2" dir tmp
  require_credentials
  case "$env" in ''|*[!A-Z0-9_]*) die "invalid credential env name '$env'" ;; esac
  yq -e ".credentials[] | select(.env == \"$env\")" "$CRED_FILE" >/dev/null \
    || die "credential '$env' is not in $CRED_FILE_REL"

  dir="$(dirname "$CRED_FILE")"
  umask 077
  tmp="$(mktemp "$dir/.credentials.XXXXXX")"
  cp "$CRED_FILE" "$tmp"
  chmod 600 "$tmp"
  SECRET_INPUT_VALUE="$val"
  export SECRET_INPUT_VALUE
  if ! yq -i "(.credentials[] | select(.env == \"$env\") | .value) = strenv(SECRET_INPUT_VALUE)" "$tmp"; then
    unset SECRET_INPUT_VALUE val
    rm -f "$tmp"
    die "failed to update $env"
  fi
  unset SECRET_INPUT_VALUE val
  mv "$tmp" "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

credential_status_word() {
  local env="$1" val="$2"
  if [ -z "$val" ]; then printf '%smissing%s' "$C_YEL" "$C_RST"; return; fi
  if validate_credential_value "$env" "$val"; then printf '%sset%s' "$C_GRN" "$C_RST"
  else printf '%sinvalid%s' "$C_RED" "$C_RST"; fi
}

cmd_secrets_status() {
  local f count i env name phase val required status any=0
  [ -z "$SECRETS_PHASE" ] || validate_phase "$SECRETS_PHASE" \
    || die "--phase must be 1, 2, 3, 4, or 5"
  f="$(credential_read_file)"
  [ -f "$CRED_FILE" ] || warn "$CRED_FILE_REL not initialized — showing template state"
  info "Credential status  ${C_DIM}${SECRETS_PHASE:+phase=$SECRETS_PHASE}${C_RST}"
  printf '  %-4s %-34s %-10s %s\n' PHASE ENV STATUS NAME
  count="$(yq '.credentials | length' "$f")"
  i=0
  while [ "$i" -lt "$count" ]; do
    env="$(yq -r ".credentials[$i].env // \"\"" "$f")"
    name="$(yq -r ".credentials[$i].name // \"\"" "$f")"
    phase="$(yq -r ".credentials[$i].phase // \"\"" "$f")"
    val="$(yq -r ".credentials[$i].value // \"\"" "$f")"
    required="$(yq -r ".credentials[$i].required" "$f")"
    i=$((i + 1))
    credential_in_scope "$phase" || continue
    [ -z "$SECRETS_ONLY" ] || [ "$env" = "$SECRETS_ONLY" ] || continue
    [ "$required" != "false" ] || name="$name (optional)"
    status="$(credential_status_word "$env" "$val")"
    printf '  %-4s %-34s %-10s %s\n' "$phase" "$env" "$status" "$name"
    any=1
  done
  if [ "$any" -eq 0 ]; then
    if [ -n "$SECRETS_PHASE" ]; then ok "Phase $SECRETS_PHASE requires no dedicated credentials"
    else warn "no credentials matched the selection"; fi
  fi
}

cmd_secrets_validate() {
  local f count i env name phase val any=0 fail=0
  [ -z "$SECRETS_PHASE" ] || validate_phase "$SECRETS_PHASE" \
    || die "--phase must be 1, 2, 3, 4, or 5"
  f="$(credential_read_file)"
  info "Credential validation  ${C_DIM}(offline format checks; values are never printed)${C_RST}"
  count="$(yq '.credentials | length' "$f")"
  i=0
  while [ "$i" -lt "$count" ]; do
    env="$(yq -r ".credentials[$i].env // \"\"" "$f")"
    name="$(yq -r ".credentials[$i].name // \"\"" "$f")"
    phase="$(yq -r ".credentials[$i].phase // \"\"" "$f")"
    val="$(yq -r ".credentials[$i].value // \"\"" "$f")"
    i=$((i + 1))
    credential_in_scope "$phase" || continue
    [ -z "$SECRETS_ONLY" ] || [ "$env" = "$SECRETS_ONLY" ] || continue
    any=1
    if validate_credential_value "$env" "$val"; then ok "$(printf '%-34s' "$env") $VALIDATION_MESSAGE"
    else
      case "$?" in
        2) warn "$(printf '%-34s' "$env") missing" ;;
        *) bad "$(printf '%-34s' "$env") $VALIDATION_MESSAGE"; fail=1 ;;
      esac
    fi
  done
  [ "$any" -eq 1 ] || ok "selected phase requires no dedicated credentials"
  [ "$fail" -eq 0 ] || die "credential validation failed"
}

prompt_secret_value() {
  local env="$1" val had_x=0
  [ -t 0 ] || die "secret input requires an interactive terminal"
  case "$-" in *x*) had_x=1; set +x ;; esac
  printf 'Enter %s (input hidden): ' "$env" >&2
  IFS= read -r -s val
  printf '\n' >&2
  PROMPTED_SECRET_VALUE="$val"
  [ "$had_x" -eq 0 ] || set +x
}

prompt_config_value() {
  local env="$1" val
  printf 'Enter %s: ' "$env" >&2
  IFS= read -r val
  PROMPTED_SECRET_VALUE="$val"
}

classify_credential_technology() {
  case "$1" in
    OPENAI_API_KEY|ANTHROPIC_API_KEY)
      CREDENTIAL_GROUP_ID="providers"; CREDENTIAL_GROUP_NAME="Model providers" ;;
    LITELLM_*)
      CREDENTIAL_GROUP_ID="litellm"; CREDENTIAL_GROUP_NAME="LiteLLM" ;;
    UI_USERNAME|UI_PASSWORD)
      CREDENTIAL_GROUP_ID="litellm"; CREDENTIAL_GROUP_NAME="LiteLLM" ;;
    LANGFUSE_*|NEXTAUTH_SECRET)
      CREDENTIAL_GROUP_ID="langfuse"; CREDENTIAL_GROUP_NAME="Langfuse" ;;
    REDIS_*)
      CREDENTIAL_GROUP_ID="redis"; CREDENTIAL_GROUP_NAME="Redis" ;;
    CLICKHOUSE_PASSWORD|CLICKHOUSE_USER)
      CREDENTIAL_GROUP_ID="clickhouse"; CREDENTIAL_GROUP_NAME="ClickHouse (local)" ;;
    POSTGRES_*)
      CREDENTIAL_GROUP_ID="postgres"; CREDENTIAL_GROUP_NAME="PostgreSQL" ;;
    MINIO_*)
      CREDENTIAL_GROUP_ID="minio"; CREDENTIAL_GROUP_NAME="MinIO (Langfuse)" ;;
    LIBRECHAT_*)
      CREDENTIAL_GROUP_ID="librechat"; CREDENTIAL_GROUP_NAME="LibreChat" ;;
    CLICKHOUSE_CLOUD_*|MCP_CLICKHOUSE_*)
      CREDENTIAL_GROUP_ID="clickhouse-cloud"; CREDENTIAL_GROUP_NAME="ClickHouse Cloud / MCP" ;;
    RUNPOD_*|VLLM_*|HF_TOKEN)
      CREDENTIAL_GROUP_ID="serving"; CREDENTIAL_GROUP_NAME="RunPod / vLLM / Hugging Face" ;;
    AWS_*)
      CREDENTIAL_GROUP_ID="aws"; CREDENTIAL_GROUP_NAME="AWS authentication / EC2" ;;
    ARTIFACT_MINIO_*)
      CREDENTIAL_GROUP_ID="artifact-minio"; CREDENTIAL_GROUP_NAME="Artifact MinIO" ;;
    *)
      CREDENTIAL_GROUP_ID="other"; CREDENTIAL_GROUP_NAME="Other" ;;
  esac
}

copy_credential_value() {
  local env="$1" val="$2"
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$val" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$val" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$val" | xclip -selection clipboard
  else
    warn "no clipboard command found (pbcopy, wl-copy, or xclip)"
    return 1
  fi
  ok "$env copied to the clipboard; overwrite the clipboard after use"
}

reveal_credential_value() {
  local env="$1" val="$2" confirm
  printf '  Reveal %s in terminal scrollback? [y/N]: ' "$env" >&2
  IFS= read -r confirm
  case "$confirm" in
    y|Y) printf '%s=%s\n' "$env" "$val" ;;
    *) ok "$env kept hidden" ;;
  esac
}

validate_default_credential_id() {
  local val="$1"
  [ "${#val}" -ge 3 ] && [ "${#val}" -le 32 ] \
    || { VALIDATION_MESSAGE="use 3..32 characters"; return 1; }
  case "$val" in
    [a-z]*)
      case "$val" in
        *[!a-z0-9_-]*) VALIDATION_MESSAGE="use lowercase letters, numbers, _ or -"; return 1 ;;
      esac ;;
    *) VALIDATION_MESSAGE="start with a lowercase letter"; return 1 ;;
  esac
  VALIDATION_MESSAGE="valid default ID"
}

validate_default_credential_password() {
  local val="$1"
  [ "${#val}" -ge 12 ] \
    || { VALIDATION_MESSAGE="use at least 12 characters"; return 1; }
  case "$val" in
    *[!A-Za-z0-9._~-]*)
      VALIDATION_MESSAGE="use URL-safe letters, numbers, dot, underscore, tilde, or hyphen"
      return 1 ;;
  esac
  case "$val" in *[a-z]*) : ;; *) VALIDATION_MESSAGE="include a lowercase letter"; return 1 ;; esac
  case "$val" in *[A-Z]*) : ;; *) VALIDATION_MESSAGE="include an uppercase letter"; return 1 ;; esac
  case "$val" in *[0-9]*) : ;; *) VALIDATION_MESSAGE="include a number"; return 1 ;; esac
  VALIDATION_MESSAGE="valid default password"
}

set_default_credentials() {
  local id email password confirm i index kind env changed=0
  local id_count=0 email_count=0 password_count=0
  local dir updates_tmp inventory_tmp

  say ""
  info "Set default credentials"
  say "  ${C_DIM}Each technology receives the login field it supports: ID, email, or password.${C_RST}"
  say "  ${C_DIM}API keys, signing keys, encryption keys, and external credentials stay unique.${C_RST}"
  warn "Use before first startup, or coordinate credential rotation for existing persistent volumes."

  i=0
  while [ "$i" -lt "$menu_count" ]; do
    index="${menu_indices[$i]}"
    case "${inventory_default_credentials[$index]}" in
      id) id_count=$((id_count + 1)) ;;
      email) email_count=$((email_count + 1)) ;;
      password) password_count=$((password_count + 1)) ;;
    esac
    i=$((i + 1))
  done
  if [ "$id_count" -eq 0 ] && [ "$email_count" -eq 0 ] && [ "$password_count" -eq 0 ]; then
    ok "the current selection has no default credential fields"
    return 0
  fi

  if [ "$id_count" -gt 0 ]; then
    prompt_config_value "DEFAULT_ID"
    id="$PROMPTED_SECRET_VALUE"; unset PROMPTED_SECRET_VALUE
    if ! validate_default_credential_id "$id"; then
      warn "default ID rejected: $VALIDATION_MESSAGE"
      return 0
    fi
  fi
  if [ "$email_count" -gt 0 ]; then
    prompt_config_value "DEFAULT_EMAIL"
    email="$PROMPTED_SECRET_VALUE"; unset PROMPTED_SECRET_VALUE
    if ! validate_credential_value "LANGFUSE_INIT_USER_EMAIL" "$email"; then
      warn "default email rejected: $VALIDATION_MESSAGE"
      return 0
    fi
  fi
  if [ "$password_count" -gt 0 ]; then
    prompt_secret_value "DEFAULT_PASSWORD"
    password="$PROMPTED_SECRET_VALUE"; unset PROMPTED_SECRET_VALUE
    if ! validate_default_credential_password "$password"; then
      unset password
      warn "default password rejected: $VALIDATION_MESSAGE"
      return 0
    fi
  fi

  say "  Will set ${C_B}$id_count ID${C_RST}, ${C_B}$email_count email${C_RST}, and ${C_B}$password_count password${C_RST} field(s) in the current selection."
  printf '  Replace those fields with the default credentials? [y/N]: ' >&2
  IFS= read -r confirm
  case "$confirm" in
    y|Y) : ;;
    *) unset password; ok "default credentials were not applied"; return 0 ;;
  esac

  dir="$(dirname "$CRED_FILE")"
  umask 077
  updates_tmp="$(mktemp "$dir/.default-credentials.XXXXXX")"
  inventory_tmp="$(mktemp "$dir/.credentials.XXXXXX")"
  chmod 600 "$updates_tmp" "$inventory_tmp"
  trap 'rm -f "$updates_tmp" "$inventory_tmp"' HUP INT TERM

  i=0
  while [ "$i" -lt "$menu_count" ]; do
    index="${menu_indices[$i]}"
    kind="${inventory_default_credentials[$index]}"
    env="${inventory_envs[$index]}"
    case "$kind" in
      id)
        printf '%s=%s\n' "$env" "$id" >> "$updates_tmp"
        inventory_values[$index]="$id"
        changed=$((changed + 1)) ;;
      email)
        printf '%s=%s\n' "$env" "$email" >> "$updates_tmp"
        inventory_values[$index]="$email"
        changed=$((changed + 1)) ;;
      password)
        printf '%s=%s\n' "$env" "$password" >> "$updates_tmp"
        inventory_values[$index]="$password"
        changed=$((changed + 1)) ;;
    esac
    i=$((i + 1))
  done

  if ! CRED_PRIVATE_PATH="$CRED_FILE" COMMON_ACCOUNT_PATH="$updates_tmp" \
    yq -n '
      load(strenv(CRED_PRIVATE_PATH)) as $private |
      load_props(strenv(COMMON_ACCOUNT_PATH)) as $updates |
      $private |
      .credentials[] |= (
        .value = ($updates[.env] // .value)
      )
    ' > "$inventory_tmp"; then
    unset password
    rm -f "$updates_tmp" "$inventory_tmp"
    die "failed to store default credentials; the original was preserved"
  fi
  yq -e '.credentials | type == "!!seq"' "$inventory_tmp" >/dev/null \
    || {
      unset password
      rm -f "$updates_tmp" "$inventory_tmp"
      die "default credential update was invalid; the original was preserved"
    }
  mv "$inventory_tmp" "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  rm -f "$updates_tmp"
  trap - HUP INT TERM
  unset password
  setup_dirty=1
  ok "$changed default credential fields updated; values were not printed"
  warn "Choose [w] to refresh .env before starting the stack."
}

cmd_secrets_set() {
  local env="$SECRETS_ONLY" val
  require_credentials
  [ -n "$env" ] || die "usage: ./scripts/stack.sh secrets set <ENV_NAME>"
  case "$env" in *[!A-Z0-9_]*) die "invalid credential name '$env'" ;; esac
  yq -e ".credentials[] | select(.env == \"$env\")" "$CRED_FILE" >/dev/null \
    || die "unknown credential '$env'"
  prompt_secret_value "$env"
  val="$PROMPTED_SECRET_VALUE"; unset PROMPTED_SECRET_VALUE
  if ! validate_credential_value "$env" "$val"; then
    unset val
    die "$env rejected: $VALIDATION_MESSAGE"
  fi
  persist_credential_value "$env" "$val"
  unset val
  ok "$env stored and validated"
}

cmd_secrets_generate() {
  local count i env phase val gen id any=0 changed=0
  require_credentials
  select_secrets_phase
  count="$(cq '.credentials | length')"
  i=0
  while [ "$i" -lt "$count" ]; do
    env="$(cq ".credentials[$i].env")"
    phase="$(cq ".credentials[$i].phase")"
    val="$(cq ".credentials[$i].value")"
    gen="$(credential_generator_spec "$env" "$(cq ".credentials[$i].generate")")"
    i=$((i + 1))
    credential_in_scope "$phase" || continue
    [ -z "$SECRETS_ONLY" ] || [ "$env" = "$SECRETS_ONLY" ] || continue
    [ -n "$gen" ] || continue
    any=1
    if [ -n "$val" ] && [ "$SECRETS_FORCE" -eq 0 ]; then
      ok "$(printf '%-34s' "$env") already set — kept"
      continue
    fi
    id="$(credential_generator_id "$gen")" || die "$env has an unsupported generator"
    generate_credential_value "$id" || die "$env generation failed: $VALIDATION_MESSAGE"
    validate_credential_value "$env" "$GENERATED_VALUE" \
      || die "$env generator produced an invalid value: $VALIDATION_MESSAGE"
    persist_credential_value "$env" "$GENERATED_VALUE"
    unset GENERATED_VALUE val
    ok "$(printf '%-34s' "$env") generated and stored"
    changed=$((changed + 1))
  done
  [ "$any" -eq 1 ] || ok "selected phase has no locally generated credentials"
  say "${C_DIM}$changed credential(s) generated; no values were printed${C_RST}"
}

configure_external_credential() {
  local index="$1" env name val console required status action retry input gen id
  env="${inventory_envs[$index]}"
  name="${inventory_names[$index]}"
  case "$env" in
    AWS_PROFILE) name="AWS SSO profile" ;;
    AWS_ACCESS_KEY_ID) name="AWS access key ID (static fallback)" ;;
    AWS_SECRET_ACCESS_KEY) name="AWS secret access key (static fallback)" ;;
  esac
  console="${inventory_consoles[$index]}"
  required="${inventory_required[$index]}"
  input="${inventory_inputs[$index]}"
  gen="${inventory_generators[$index]}"

  while :; do
    val="${inventory_values[$index]}"
    status="$(credential_status_word "$env" "$val")"
    say ""
    if [ "$required" = "false" ]; then
      say "${C_B}$env${C_RST} — $name (optional)  [$status]"
    else
      say "${C_B}$env${C_RST} — $name  [$status]"
    fi
    [ -z "$console" ] || say "  ${C_DIM}source: $console${C_RST}"

    if [ "$input" = "generated" ]; then
      if [ -n "$val" ]; then
        printf '  [g]regenerate  [c]opy  [r]eveal  [e]replace  [d]elete  [b]ack: ' >&2
      else
        printf '  [g/Enter] generate  [e]manual entry  [b]ack: ' >&2
      fi
      IFS= read -r action
      [ -n "$action" ] || action=g
    else
      if [ -n "$val" ]; then
        printf '  [c]opy  [r]eveal  [e]replace  [d]elete  [b]ack: ' >&2
        IFS= read -r action
        [ -n "$action" ] || action=b
      else
        printf '  Press Enter to input, or [b]ack: ' >&2
        IFS= read -r action
        [ -n "$action" ] || action=e
      fi
    fi

    case "$action" in
      b|B) return 0 ;;
      c|C)
        [ -n "$val" ] || { warn "$env is empty"; continue; }
        copy_credential_value "$env" "$val" || true ;;
      r|R)
        [ -n "$val" ] || { warn "$env is empty"; continue; }
        reveal_credential_value "$env" "$val" ;;
      g|G)
        [ -n "$gen" ] || { warn "$env has no generator"; continue; }
        id="$(credential_generator_id "$gen")" || { warn "$env has an unsupported generator"; continue; }
        generate_credential_value "$id" || { warn "$env generation failed: $VALIDATION_MESSAGE"; continue; }
        if ! validate_credential_value "$env" "$GENERATED_VALUE"; then
          unset GENERATED_VALUE
          warn "$env generator produced an invalid value: $VALIDATION_MESSAGE"
          continue
        fi
        persist_credential_value "$env" "$GENERATED_VALUE"
        inventory_values[$index]="$GENERATED_VALUE"
        setup_dirty=1
        unset GENERATED_VALUE
        ok "$env generated and stored; value was not printed"
        return 0 ;;
      d|D)
        [ -n "$val" ] || { warn "$env is already empty"; continue; }
        persist_credential_value "$env" ""
        inventory_values[$index]=""
        setup_dirty=1
        ok "$env cleared"
        return 0 ;;
      e|E)
        while :; do
          if [ "$input" = "config" ] || [ "$input" = "default" ]; then prompt_config_value "$env"
          else prompt_secret_value "$env"; fi
          if validate_credential_value "$env" "$PROMPTED_SECRET_VALUE"; then
            persist_credential_value "$env" "$PROMPTED_SECRET_VALUE"
            inventory_values[$index]="$PROMPTED_SECRET_VALUE"
            setup_dirty=1
            unset PROMPTED_SECRET_VALUE
            ok "$env stored and validated"
            return 0
          fi
          unset PROMPTED_SECRET_VALUE
          warn "$env rejected: $VALIDATION_MESSAGE"
          printf '  [r]etry  [b]ack: ' >&2
          IFS= read -r retry
          case "$retry" in r|R) : ;; *) return 0 ;; esac
        done ;;
      *) warn "unknown choice '$action'" ;;
    esac
  done
}

generate_missing_setup_credentials() {
  local i gen id env changed=0 dir updates_tmp inventory_tmp
  dir="$(dirname "$CRED_FILE")"
  umask 077
  updates_tmp="$(mktemp "$dir/.generated-values.XXXXXX")"
  inventory_tmp="$(mktemp "$dir/.credentials.XXXXXX")"
  chmod 600 "$updates_tmp" "$inventory_tmp"
  trap 'rm -f "$updates_tmp" "$inventory_tmp"' HUP INT TERM
  i=0
  while [ "$i" -lt "${#inventory_envs[@]}" ]; do
    gen="${inventory_generators[$i]}"
    if [ -n "$gen" ] && [ -z "${inventory_values[$i]}" ]; then
      env="${inventory_envs[$i]}"
      id="$(credential_generator_id "$gen")" \
        || { rm -f "$updates_tmp" "$inventory_tmp"; die "$env has an unsupported generator"; }
      generate_credential_value "$id" \
        || { rm -f "$updates_tmp" "$inventory_tmp"; die "$env generation failed: $VALIDATION_MESSAGE"; }
      validate_credential_value "$env" "$GENERATED_VALUE" \
        || { rm -f "$updates_tmp" "$inventory_tmp"; unset GENERATED_VALUE; die "$env generator produced an invalid value: $VALIDATION_MESSAGE"; }
      printf '%s=%s\n' "$env" "$GENERATED_VALUE" >> "$updates_tmp"
      inventory_values[$i]="$GENERATED_VALUE"
      unset GENERATED_VALUE
      changed=$((changed + 1))
    fi
    i=$((i + 1))
  done
  if [ "$changed" -eq 0 ]; then
    rm -f "$updates_tmp" "$inventory_tmp"
    trap - HUP INT TERM
    ok "all generated credentials are already set"
    return 0
  fi
  if ! CRED_PRIVATE_PATH="$CRED_FILE" GENERATED_VALUES_PATH="$updates_tmp" \
    yq -n '
      load(strenv(CRED_PRIVATE_PATH)) as $private |
      load_props(strenv(GENERATED_VALUES_PATH)) as $updates |
      $private |
      .credentials[] |= (
        .value = ($updates[.env] // .value)
      )
    ' > "$inventory_tmp"; then
    rm -f "$updates_tmp" "$inventory_tmp"
    die "failed to store generated credentials; the original was preserved"
  fi
  yq -e '.credentials | type == "!!seq"' "$inventory_tmp" >/dev/null \
    || { rm -f "$updates_tmp" "$inventory_tmp"; die "generated credential update was invalid; the original was preserved"; }
  mv "$inventory_tmp" "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  rm -f "$updates_tmp"
  trap - HUP INT TERM
  setup_dirty=1
  ok "$changed missing generated credential(s) stored; no values were printed"
}

cmd_secrets_setup() {
  local separator=$'\x1f' count=0 i env name phase phase_name val gen input required status choice selected bootstrap_target menu_count=0
  local group_count=0 group_choice group_id group_name group_index group_total group_set sub_count sub_choice inventory_index seen
  local setup_dirty=0
  local aws_profile_value aws_access_value aws_secret_value aws_auth_status
  local inventory_envs=() inventory_phases=() inventory_values=() inventory_names=()
  local inventory_consoles=() inventory_required=() inventory_generators=()
  local inventory_inputs=() inventory_bootstrap_targets=() inventory_phase_names=()
  local inventory_default_credentials=()
  local inventory_group_ids=() inventory_group_names=()
  local menu_indices=() menu_groups=() group_ids=() group_names=() group_indices=()
  cmd_secrets_init >/dev/null
  [ -z "$SECRETS_PHASE" ] || validate_phase "$SECRETS_PHASE" \
    || die "--phase must be 1, 2, 3, 4, or 5"
  require_credentials

  while IFS="$separator" read -r env phase val name console required gen input bootstrap_target phase_name default_credential; do
    [ "$required" != "null" ] || required="true"
    if [ -z "$input" ]; then
      if [ -n "$gen" ]; then input="generated"
      else input="external"; fi
    fi
    inventory_envs[$count]="$env"
    inventory_phases[$count]="$phase"
    inventory_values[$count]="$val"
    inventory_names[$count]="$name"
    inventory_consoles[$count]="$console"
    inventory_required[$count]="$required"
    inventory_generators[$count]="$gen"
    inventory_inputs[$count]="$input"
    inventory_bootstrap_targets[$count]="$bootstrap_target"
    inventory_phase_names[$count]="$phase_name"
    inventory_default_credentials[$count]="$default_credential"
    classify_credential_technology "$env"
    inventory_group_ids[$count]="$CREDENTIAL_GROUP_ID"
    inventory_group_names[$count]="$CREDENTIAL_GROUP_NAME"
    count=$((count + 1))
  done < <(
    CRED_TEMPLATE_PATH="$CRED_TEMPLATE" \
    CRED_PRIVATE_PATH="$CRED_FILE" \
    STACK_CONFIG_PATH="$STACK_FILE" \
    FIELD_SEPARATOR="$separator" \
    yq -n -r '
      load(strenv(CRED_TEMPLATE_PATH)) as $template |
      load(strenv(CRED_PRIVATE_PATH)) as $private |
      load(strenv(STACK_CONFIG_PATH)) as $stack |
      $template.credentials[] as $item |
      (($private.credentials | map(select(.env == $item.env)) | .[0].value) // "") as $value |
      [
        ($item.env // ""),
        (($item.phase // 0) | tostring),
        $value,
        ($item.name // ""),
        ($item.console // ""),
        ($item.required | tostring),
        ($item.generate // ""),
        ($item.input // ""),
        ($item.bootstrap_target // ""),
        ($stack.phases[(($item.phase // 0) | tostring)].name // ""),
        ($item.default_credential // "")
      ] | join(strenv(FIELD_SEPARATOR))
    '
  )

  # The setup hub contains the complete inventory. Input behavior is selected
  # from metadata: external values are hidden, config/default values are
  # visible, and generated values never need to be typed.
  i=0
  while [ "$i" -lt "$count" ]; do
    env="${inventory_envs[$i]}"
    phase="${inventory_phases[$i]}"
    if [ -n "$SECRETS_PHASE" ] && [ "$phase" != "$SECRETS_PHASE" ]; then
      i=$((i + 1))
      continue
    fi
    if [ -n "$SECRETS_ONLY" ] && [ "$env" != "$SECRETS_ONLY" ]; then
      i=$((i + 1))
      continue
    fi
    menu_indices[$menu_count]="$i"
    menu_groups[$menu_count]="${inventory_group_ids[$i]}"
    menu_count=$((menu_count + 1))
    i=$((i + 1))
  done

  if [ "$menu_count" -eq 0 ]; then
    if [ -n "$SECRETS_PHASE" ]; then
      ok "Phase $SECRETS_PHASE has no credential definitions"
    else
      ok "No credentials matched the selection"
    fi
    return 0
  fi

  i=0
  while [ "$i" -lt "$menu_count" ]; do
    group_id="${menu_groups[$i]}"
    seen=0
    group_index=0
    while [ "$group_index" -lt "$group_count" ]; do
      [ "${group_ids[$group_index]}" != "$group_id" ] || { seen=1; break; }
      group_index=$((group_index + 1))
    done
    if [ "$seen" -eq 0 ]; then
      inventory_index="${menu_indices[$i]}"
      group_ids[$group_count]="$group_id"
      group_names[$group_count]="${inventory_group_names[$inventory_index]}"
      group_count=$((group_count + 1))
    fi
    i=$((i + 1))
  done

  while :; do
    say ""
    info "Credential setup  ${C_DIM}values stay hidden unless you choose reveal${C_RST}"
    say "  ${C_B}GROUPS${C_RST}"
    i=0
    while [ "$i" -lt "$group_count" ]; do
      group_id="${group_ids[$i]}"
      group_total=0
      group_set=0
      group_index=0
      while [ "$group_index" -lt "$menu_count" ]; do
        if [ "${menu_groups[$group_index]}" = "$group_id" ]; then
          group_total=$((group_total + 1))
          inventory_index="${menu_indices[$group_index]}"
          val="${inventory_values[$inventory_index]}"
          [ -z "$val" ] || group_set=$((group_set + 1))
        fi
        group_index=$((group_index + 1))
      done
      group_name="${group_names[$i]}"
      if [ "$group_id" = "aws" ]; then
        aws_profile_value=""
        aws_access_value=""
        aws_secret_value=""
        group_index=0
        while [ "$group_index" -lt "$menu_count" ]; do
          if [ "${menu_groups[$group_index]}" = "aws" ]; then
            inventory_index="${menu_indices[$group_index]}"
            case "${inventory_envs[$inventory_index]}" in
              AWS_PROFILE) aws_profile_value="${inventory_values[$inventory_index]}" ;;
              AWS_ACCESS_KEY_ID) aws_access_value="${inventory_values[$inventory_index]}" ;;
              AWS_SECRET_ACCESS_KEY) aws_secret_value="${inventory_values[$inventory_index]}" ;;
            esac
          fi
          group_index=$((group_index + 1))
        done
        if [ -n "$aws_profile_value" ]; then
          aws_auth_status="SSO profile configured"
        elif [ -n "$aws_access_value" ] && [ -n "$aws_secret_value" ]; then
          aws_auth_status="static keys configured"
        elif [ -n "$aws_access_value" ] || [ -n "$aws_secret_value" ]; then
          aws_auth_status="static key pair incomplete"
        else
          aws_auth_status="not configured"
        fi
        printf '  %s) %-40s %s · %s/%s values set\n' \
          "$((i + 1))" "$group_name" "$aws_auth_status" "$group_set" "$group_total"
      else
        printf '  %s) %-40s %s/%s configured\n' "$((i + 1))" "$group_name" "$group_set" "$group_total"
      fi
      i=$((i + 1))
    done
    say ""
    say "  ${C_DIM}[d] set default credentials   [g] generate missing internal values   [w] write .env${C_RST}"
    printf 'Select a group [1-%s], [d], [g], [w], or [q/Enter] finish: ' "$group_count" >&2
    IFS= read -r group_choice
    case "$group_choice" in
      ''|q|Q) break ;;
      d|D) set_default_credentials; continue ;;
      g|G) generate_missing_setup_credentials; continue ;;
      w|W) cmd_secrets_write; setup_dirty=0; continue ;;
      *[!0-9]*) warn "enter a number from 1 to $group_count, d, g, w, or q"; continue ;;
    esac
    [ "$group_choice" -ge 1 ] 2>/dev/null && [ "$group_choice" -le "$group_count" ] 2>/dev/null \
      || { warn "enter a number from 1 to $group_count"; continue; }
    group_id="${group_ids[$((group_choice - 1))]}"

    group_indices=()
    sub_count=0
    i=0
    while [ "$i" -lt "$menu_count" ]; do
      if [ "${menu_groups[$i]}" = "$group_id" ]; then
        group_indices[$sub_count]="${menu_indices[$i]}"
        sub_count=$((sub_count + 1))
      fi
      i=$((i + 1))
    done

    while :; do
      say ""
      if [ "$group_id" = "aws" ]; then
        info "${group_names[$((group_choice - 1))]}  ${C_DIM}SSO profile recommended; static keys are the fallback${C_RST}"
      else
        info "${group_names[$((group_choice - 1))]}"
      fi
      printf '  %-4s %-30s %-10s %-10s %s\n' NO ENV TYPE STATUS NAME
      i=0
      while [ "$i" -lt "$sub_count" ]; do
        inventory_index="${group_indices[$i]}"
        env="${inventory_envs[$inventory_index]}"
        name="${inventory_names[$inventory_index]}"
        case "$env" in
          AWS_PROFILE) name="AWS SSO profile" ;;
          AWS_ACCESS_KEY_ID) name="AWS access key ID (static fallback)" ;;
          AWS_SECRET_ACCESS_KEY) name="AWS secret access key (static fallback)" ;;
        esac
        val="${inventory_values[$inventory_index]}"
        required="${inventory_required[$inventory_index]}"
        input="${inventory_inputs[$inventory_index]}"
        status="$(credential_status_word "$env" "$val")"
        [ "$required" != "false" ] || name="$name (optional)"
        printf '  %-4s %-30s %-10s %-10s %s\n' "$((i + 1))" "$env" "$input" "$status" "$name"
        i=$((i + 1))
      done
      say ""
      printf 'Select [1-%s], [b]ack, or [q]uit: ' "$sub_count" >&2
      IFS= read -r sub_choice
      case "$sub_choice" in
        b|B|'') break ;;
        q|Q) choice=q; break 2 ;;
        *[!0-9]*) warn "enter a number from 1 to $sub_count, b, or q"; continue ;;
      esac
      [ "$sub_choice" -ge 1 ] 2>/dev/null && [ "$sub_choice" -le "$sub_count" ] 2>/dev/null \
        || { warn "enter a number from 1 to $sub_count"; continue; }
      selected="${group_indices[$((sub_choice - 1))]}"
      configure_external_credential "$selected"
    done
  done

  if [ "$setup_dirty" -eq 1 ]; then
    warn "credential changes are stored, but .env was not refreshed — choose [w] or run: ./scripts/stack.sh secrets write"
  else
    ok "credential setup finished"
  fi
}

# credentials.yaml -> .env
cmd_secrets_write() {
  require_credentials
  local separator=$'\x1f' envf dir tmp i count=0 name env val ph blank=0 escaped reviewed
  local write_envs=() write_values=() write_names=() write_phases=()
  envf="$REPO_ROOT/$(qs '.secrets.file')"
  [ ! -L "$envf" ] || die "${envf#"$REPO_ROOT/"} must not be a symlink"
  [ ! -L "$envf.bak" ] || die "${envf#"$REPO_ROOT/"}.bak must not be a symlink"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run — would atomically write $(printf '%s' "${envf#"$REPO_ROOT/"}")"
    cmd_secrets_status
    return 0
  fi

  dir="$(dirname "$envf")"
  umask 077
  tmp="$(mktemp "$dir/.env.tmp.XXXXXX")"
  reviewed="$(cq '.meta.last_reviewed')"
  while IFS="$separator" read -r env val name ph; do
    write_envs[$count]="$env"
    write_values[$count]="$val"
    write_names[$count]="$name"
    write_phases[$count]="$ph"
    count=$((count + 1))
  done < <(
    FIELD_SEPARATOR="$separator" yq -r '
      .credentials[] |
      [(.env // ""), (.value // ""), (.name // ""), ((.phase // 0) | tostring)] |
      join(strenv(FIELD_SEPARATOR))
    ' "$CRED_FILE"
  )

  # A manually edited inventory must pass the same checks as wizard input
  # before it can replace the runtime file.
  i=0
  while [ "$i" -lt "$count" ]; do
    env="${write_envs[$i]}"
    val="${write_values[$i]}"
    i=$((i + 1))
    [ -z "$val" ] && continue
    if ! validate_credential_value "$env" "$val"; then
      rm -f "$tmp"
      die "$env is invalid: $VALIDATION_MESSAGE"
    fi
  done

  if ! {
    printf '# GENERATED by `stack.sh secrets write` from %s — DO NOT EDIT.\n' "$CRED_FILE_REL"
    printf '# Edit %s, then re-run. Reviewed: %s\n\n' "$CRED_FILE_REL" "$reviewed"
    i=0
    while [ "$i" -lt "$count" ]; do
      env="${write_envs[$i]}"
      val="${write_values[$i]}"
      name="${write_names[$i]}"
      ph="${write_phases[$i]}"
      i=$((i + 1))
      [ -n "$env" ] || continue
      printf '# %s (phase %s)\n' "$name" "$ph"
      # Compose treats single-quoted dotenv values literally. Only a literal
      # single quote needs escaping in that representation.
      escaped="$val"
      escaped="${escaped//\'/\\\'}"
      printf "%s='%s'\n" "$env" "$escaped"
    done
  } > "$tmp"; then
    rm -f "$tmp"
    die "failed to render .env; existing file was not changed"
  fi

  chmod 600 "$tmp"
  if [ -f "$envf" ]; then
    cp "$envf" "$envf.bak"
    chmod 600 "$envf.bak"
    warn "existing .env backed up to .env.bak (mode 600)"
  fi
  mv "$tmp" "$envf"
  chmod 600 "$envf"
  ok "wrote $(printf '%s' "${envf#"$REPO_ROOT/"}") (mode 600) from $CRED_FILE_REL"

  i=0
  while [ "$i" -lt "$count" ]; do
    env="${write_envs[$i]}"; val="${write_values[$i]}"
    i=$((i + 1))
    [ -n "$env" ] && [ -z "$val" ] && blank=$((blank + 1))
  done
  [ "$blank" -gt 0 ] && warn "$blank of $count credentials still blank — run: ./scripts/stack.sh doctor"
  return 0
}

# Verify nothing sensitive can reach git, Docker, or an AI tool's index.
cmd_secrets_audit() {
  local fail=0 generator_fail=0 f p mode count i env gen
  local guarded=".env .env.bak $CRED_FILE_REL"

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

  info "Local file permissions"
  for p in .env .env.bak "$CRED_FILE_REL"; do
    [ -e "$REPO_ROOT/$p" ] || continue
    if [ -L "$REPO_ROOT/$p" ]; then
      bad "$p is a symlink — refusing an ambiguous secret target"; fail=1
      continue
    fi
    mode="$(stat -f '%Lp' "$REPO_ROOT/$p" 2>/dev/null || stat -c '%a' "$REPO_ROOT/$p" 2>/dev/null || true)"
    if [ "$mode" = "600" ]; then ok "$p mode 600"
    else bad "$p mode is ${mode:-unknown}, expected 600"; fail=1; fi
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
    if yq -e '[.credentials[].value] | map(select(. != "" and . != "admin" and . != "minio" and . != "clickhouse" and . != "postgres" and . != "ap-northeast-2")) | length == 0' \
         "$REPO_ROOT/secrets/credentials.example.yaml" >/dev/null 2>&1; then
      ok "credentials.example.yaml has no real values"
    else
      bad "credentials.example.yaml contains a non-empty value — scrub it"; fail=1
    fi

    count="$(yq '.credentials | length' "$REPO_ROOT/secrets/credentials.example.yaml")"
    i=0
    while [ "$i" -lt "$count" ]; do
      env="$(yq -r ".credentials[$i].env // \"\"" "$REPO_ROOT/secrets/credentials.example.yaml")"
      gen="$(yq -r ".credentials[$i].generate // \"\"" "$REPO_ROOT/secrets/credentials.example.yaml")"
      i=$((i + 1))
      [ -z "$gen" ] && continue
      if credential_generator_id "$gen" >/dev/null; then :
      else bad "$env uses a generator outside the allowlist"; fail=1; generator_fail=1
      fi
    done
    [ "$generator_fail" -ne 0 ] || ok "all template generators are allowlisted IDs"
  fi

  say ""
  if [ "$fail" -eq 0 ]; then say "${C_GRN}${C_B}secrets audit passed${C_RST}"
  else die "secrets audit FAILED — do not commit until the ✗ items are fixed"; fi
}

cmd_secrets() {
  case "${SECRETS_SUB:-}" in
    init)              cmd_secrets_init ;;
    setup)             cmd_secrets_setup ;;
    set)               cmd_secrets_set ;;
    generate|gen)      cmd_secrets_generate ;;
    status)            cmd_secrets_status ;;
    validate)          cmd_secrets_validate ;;
    write)             cmd_secrets_write ;;
    audit)             cmd_secrets_audit ;;
    *) die "usage: ./scripts/stack.sh secrets <init|setup|set|generate|status|validate|write|audit>" ;;
  esac
}

cmd_phases() {
  local cur n name st scope mark adds_l adds_m
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
    # A phase can legitimately add nothing — Phase 5 is recipes over existing
    # layers. Print an em dash rather than a blank, so "adds nothing" reads as
    # deliberate instead of as a lookup that came back empty.
    adds_l="$(q ".phases.\"$n\".adds_layers | join(\", \")")"
    adds_m="$(q ".phases.\"$n\".adds_models | join(\", \")")"
    printf '    %slayers:%s %s   %smodels:%s %s\n' \
      "$C_DIM" "$C_RST" "${adds_l:-—}" \
      "$C_DIM" "$C_RST" "${adds_m:-—}"
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
  secrets init       Create or synchronize the private inventory (mode 600)
  secrets setup      Configure all stack technologies from one menu
  secrets set NAME   Set one credential with hidden input and format validation
  secrets generate   Generate and store local credentials without printing them
  secrets status     Show set / missing / invalid state without showing values
  secrets validate   Run offline format validation without showing values
  secrets write   Generate .env from secrets/credentials.yaml
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
      --phase <1..5>     secrets: operate on one build-out phase
      --only <ENV_NAME>  secrets: operate on one credential
      --force            secrets generate: replace values that are already set
      --all              doctor/secrets: include every phase
      --no-render        Skip config rendering on \`up\`
      --purge            On \`down\`, also delete volumes (DESTRUCTIVE)
  -n, --dry-run          Print the commands instead of running them
  -f, --file <path>      Alternate stack.yaml
  -h, --help             This message

${C_B}EXAMPLES${C_RST}
  ./scripts/stack.sh secrets setup
  ./scripts/stack.sh secrets status --phase 1
  ./scripts/stack.sh secrets generate --phase 1
  ./scripts/stack.sh secrets set OPENAI_API_KEY
  ./scripts/stack.sh secrets validate --all
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
      init|setup|set|generate|gen|status|validate|write|audit)
        SECRETS_SUB="$1"; shift
        if [ "$SECRETS_SUB" = "set" ] && [ $# -gt 0 ]; then
          case "$1" in -*) : ;; *) SECRETS_ONLY="$1"; shift ;; esac
        fi
        ;;
      *) die "usage: ./scripts/stack.sh secrets <init|setup|set|generate|status|validate|write|audit>" ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -t|--target)  TARGET="$2"; shift 2 ;;
      -p|--profile) PROFILE="$2"; shift 2 ;;
      -f|--file)    STACK_FILE="$2"; shift 2 ;;
      --tf-var)     TF_VARS="$TF_VARS$2
"; shift 2 ;;
      --phase)      SECRETS_PHASE="$2"; shift 2 ;;
      --only)       SECRETS_ONLY="$2"; shift 2 ;;
      --force)      SECRETS_FORCE=1; shift ;;
      --all)        SHOW_ALL=1; shift ;;
      --no-render)  DO_RENDER=0; shift ;;
      --purge)      PURGE=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [ "$SHOW_ALL" -eq 0 ] || [ -z "$SECRETS_PHASE" ] \
    || die "--all and --phase cannot be used together"
  case "$SECRETS_ONLY" in
    *[!A-Z0-9_]*) die "--only requires an uppercase ENV_NAME" ;;
  esac

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
