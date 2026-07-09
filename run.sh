#!/usr/bin/env bash
# private-ai-inference — single interactive entry point.
#
#   ./run.sh
#
# First run: prompts for your Vast.ai API key (+ SSH key path, + optional GPU
# gateway repo + read-only deploy key) and writes them to .env (gitignored).
# Then it walks you through the whole flow:
#   1. list your existing Vast instances -> reuse one, or rent a new box ("shop"),
#   2. (rent only) pick which fleet models to co-host (select-models.sh),
#   3. (rent only) show the 1.25x-largest-local-model VRAM sizing,
#   4. (rent only) choose market type: ondemand / bid (spot) / reserved,
#   5. hand off to scripts/deploy.sh: provision (or connect), deploy the GPU
#      repo if configured, wait for models, stand up the reverse SSH tunnel,
#      and test through it.
#
# Re-running ./run.sh reuses the saved .env (only prompts for anything missing).
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
ask() { # ask "prompt" "varname" "default" [secret]
  local prompt="$1" name="$2" default="${3:-}" secret="${4:-}"
  local cur=""; cur="${!name:-}"
  if [[ -n "$cur" ]]; then
    # already set (from .env / env); keep unless caller forces re-entry
    printf '%s' "$cur" > /dev/null
    return 0
  fi
  if [[ -n "$default" ]]; then prompt="${prompt} [${default}]"; fi
  if [[ "$secret" == "secret" ]]; then
    read -rs -p "${prompt}: " ans; echo
  else
    read -r -p "${prompt}: " ans
  fi
  ans="${ans:-$default}"
  printf -v "$name" '%s' "$ans"
}

# Validate the Vast API key with a live call BEFORE accepting it. Returns 0
# only if the API answers success:true, so a blank/wrong key is never written
# to .env (which is what caused the confusing "API error — will rent a new box"
# even when you had a real instance on the account).
validate_vast_key() {
  local key="$1" body succ err url
  url="${VAST_API_URL:-https://console.vast.ai}"
  # v0 /api/v0/instances/ is deprecated (410 for valid keys); validate against v1.
  body="$(curl -sS -G \
    --url "${url%/}/api/v1/instances/" \
    --header "Authorization: Bearer ${key}" \
    --header "Content-Type: application/json" \
    --data-urlencode "limit=1" \
    --data-urlencode 'select_cols=["id"]' \
    --data-urlencode 'select_filters={}' 2>/dev/null || true)"
  if [[ -z "$body" ]]; then
    echo "    Network error reaching the Vast API (no response)." >&2
    return 1
  fi
  succ="$(printf '%s' "$body" | jq -r '.success // empty' 2>/dev/null || true)"
  if [[ "$succ" == "true" ]]; then return 0; fi
  err="$(printf '%s' "$body" | jq -r '.error // .msg // "unknown error"' 2>/dev/null || true)"
  echo "    Vast API rejected the key: ${err}" >&2
  echo "    Get/verify it at https://console.vast.ai/account/ and re-enter." >&2
  return 1
}

# File exists and is readable.
require_file() { [[ -n "$1" && -r "$1" ]]; }

# ---- 0. load existing .env (if any), then fill gaps interactively ----
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE" 2>/dev/null || true; set +a; fi

echo "=== private-ai-inference setup ==="
echo "(Answers are saved to .env, which is gitignored. Edit it anytime.)"
echo
while true; do
  ask "  Vast.ai API key (https://console.vast.ai/account/)" VAST_API_KEY "" secret
  if validate_vast_key "$VAST_API_KEY"; then break; fi
  VAST_API_KEY=""   # bad/blank -> force re-prompt on the next iteration
done
while true; do
  ask "  Path to your Vast SSH key (for ssh_direct)" PRIVATE_AI_SSH_KEY "$HOME/.ssh/vast_ed25519"
  if require_file "$PRIVATE_AI_SSH_KEY"; then break; fi
  echo "    Not found or not readable: $PRIVATE_AI_SSH_KEY" >&2
  PRIVATE_AI_SSH_KEY=""
done
echo
echo "  Optional: GPU gateway repo to clone onto the box (it runs install.sh"
echo "  and loads the models). Leave blank to pull the selected fleet models"
echo "  directly in the box onstart instead."
while true; do
  ask "  GPU repo URL (blank to skip)" PRIVATE_AI_GPU_REPO ""
  if [[ -z "${PRIVATE_AI_GPU_REPO:-}" ]]; then break; fi
  case "$PRIVATE_AI_GPU_REPO" in
    https://github.com/*|git@github.com:*) break ;;
    *) echo "    Expected a GitHub URL (https://github.com/OWNER/REPO(.git) or git@github.com:OWNER/REPO(.git))." >&2; PRIVATE_AI_GPU_REPO="" ;;
  esac
done
if [[ -n "${PRIVATE_AI_GPU_REPO:-}" ]]; then
  ask "  GPU repo entrypoint command" PRIVATE_AI_GPU_REPO_CMD "./install.sh"
  echo "  If that repo is PRIVATE, you need a read-only GitHub deploy key"
  echo "  (scripts/new-deploy-key.sh makes one; paste its PUBLIC half into the"
  echo "  repo's Settings → Deploy keys). Point at the PRIVATE half here, or"
  echo "  leave blank if the repo is public."
  while true; do
    ask "  Path to the deploy private key (blank if repo is public)" PRIVATE_AI_GPU_DEPLOY_KEY ""
    if [[ -z "${PRIVATE_AI_GPU_DEPLOY_KEY:-}" ]]; then break; fi   # public repo -> no key
    if require_file "$PRIVATE_AI_GPU_DEPLOY_KEY"; then break; fi
    echo "    Not found or not readable: $PRIVATE_AI_GPU_DEPLOY_KEY (leave blank if repo is public)" >&2
    PRIVATE_AI_GPU_DEPLOY_KEY=""
  done
fi

# ---- write .env (managed vars only; preserved values come from the load above) ----
{
  echo "# private-ai-inference — generated by ./run.sh. Gitignored. Edit anytime."
  echo "export VAST_API_KEY=\"${VAST_API_KEY}\""
  echo "export PRIVATE_AI_SSH_KEY=\"${PRIVATE_AI_SSH_KEY}\""
  [[ -n "${PRIVATE_AI_GPU_REPO:-}" ]] && echo "export PRIVATE_AI_GPU_REPO=\"${PRIVATE_AI_GPU_REPO}\""
  [[ -n "${PRIVATE_AI_GPU_REPO_CMD:-}" ]] && echo "export PRIVATE_AI_GPU_REPO_CMD=\"${PRIVATE_AI_GPU_REPO_CMD}\""
  [[ -n "${PRIVATE_AI_GPU_DEPLOY_KEY:-}" ]] && echo "export PRIVATE_AI_GPU_DEPLOY_KEY=\"${PRIVATE_AI_GPU_DEPLOY_KEY}\""
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "  saved -> $ENV_FILE"
echo

export VAST_API_KEY PRIVATE_AI_SSH_KEY
[[ -n "${PRIVATE_AI_GPU_REPO:-}" ]] && export PRIVATE_AI_GPU_REPO
[[ -n "${PRIVATE_AI_GPU_REPO_CMD:-}" ]] && export PRIVATE_AI_GPU_REPO_CMD
[[ -n "${PRIVATE_AI_GPU_DEPLOY_KEY:-}" ]] && export PRIVATE_AI_GPU_DEPLOY_KEY

deploy_args=(--ssh-key "$PRIVATE_AI_SSH_KEY")
[[ -n "${PRIVATE_AI_GPU_REPO:-}" ]] && deploy_args+=(--model-repo "$PRIVATE_AI_GPU_REPO")
[[ -n "${PRIVATE_AI_GPU_REPO_CMD:-}" ]] && deploy_args+=(--model-repo-cmd "$PRIVATE_AI_GPU_REPO_CMD")
[[ -n "${PRIVATE_AI_GPU_DEPLOY_KEY:-}" ]] && deploy_args+=(--model-repo-key "$PRIVATE_AI_GPU_DEPLOY_KEY")

# ---- 1. reuse an existing instance, or rent a new box ("shop")? ----
echo "=== existing Vast.ai instances on your account ==="
list_out="$(scripts/list-instances.sh --list-only 2>/dev/null || true)"
if [[ -n "$list_out" ]]; then
  echo "$list_out"
  echo
  read -r -p "Reuse one of the above (enter its ID), or rent a new box (enter 'new')? [new] " choice
  choice="${choice:-new}"
else
  # API key was already validated above, so empty output means the account
  # genuinely has no instances yet (not an auth error).
  echo "  No instances on your account yet — will rent a new box."
  choice="new"
fi

if [[ "$choice" != "new" ]]; then
  echo ">>> reusing instance ${choice}"
  exec scripts/deploy.sh --reuse-instance "$choice" "${deploy_args[@]}"
fi

# ---- 2/3. pick models + show 1.25x sizing ----
echo
echo "=== pick which fleet models to co-host ==="
# select-models.sh prints its menu + sizing summary to STDERR (so it shows live
# here) and emits only the machine-readable SELECTED: line to stdout, which we
# capture. Don't echo sel_out back — it's just the machine line.
sel_out="$(scripts/select-models.sh)"
line="$(printf '%s\n' "$sel_out" | grep '^SELECTED:')"
joined="${line#SELECTED:}"; joined="${joined%% *}"
[[ -z "$joined" ]] && { echo "No models selected." >&2; exit 1; }
deploy_args+=(--models "$joined")

# ---- 4. market type ----
echo
echo "=== choose market type ==="
echo "  ondemand  — fixed on-demand rates (default, stable)"
echo "  bid       — interruptible/spot (cheapest, may be preempted if outbid)"
echo "  reserved  — reserved pricing"
read -r -p "Market type [ondemand]: " mt
mt="${mt:-ondemand}"
case "$mt" in
  ondemand|bid|reserved) deploy_args+=(--market-type "$mt") ;;
  *) echo "Invalid market type: $mt (use ondemand, bid, or reserved)" >&2; exit 2 ;;
esac

echo
echo ">>> launching deploy.sh ${deploy_args[*]}"
exec scripts/deploy.sh "${deploy_args[@]}"