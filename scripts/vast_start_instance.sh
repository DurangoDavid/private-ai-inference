#!/usr/bin/env bash
# Start (resume) an exited/stopped Vast.ai instance and wait for it to reach
# 'running'. Uses the v0 instance-state PUT ({"state":"running"}) — there is no
# v1 equivalent. Billing resumes at the instance's dph_total once it starts.
# The caller is responsible for confirming the spend; this script just acts.
#
#   vast_start_instance.sh --instance-id <id> [--vast-api-url <url>] [--timeout <sec>]
#
# Env: VAST_API_KEY. On success prints instance_info JSON (id, status, ip,
# ssh_host_port) to stdout (same shape vast_instance_info.sh emits).
set -euo pipefail
cd "$(dirname "$0")/.."

vast_api_url="${VAST_API_URL:-https://console.vast.ai}"
instance_id=""
timeout_sec=600 # starting + boot can take a few minutes

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) instance_id="$2"; shift 2 ;;
    --vast-api-url) vast_api_url="$2"; shift 2 ;;
    --timeout) timeout_sec="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env)}"
[[ -n "$instance_id" ]] || { echo "--instance-id required" >&2; exit 2; }

echo ">>> starting instance ${instance_id} (PUT /api/v0/instances/${instance_id}/ state=running)..." >&2
resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT
# Drop -f: Vast returns HTTP 200 with success:false for a QUEUED start, and we
# need the body to tell a queue apart from a real rejection. Without -f, curl
# always exits 0 on any HTTP response, so we classify from the JSON below.
curl -sS --request PUT \
  --url "${vast_api_url%/}/api/v0/instances/${instance_id}/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{"state":"running"}' > "$resp"
success="$(jq -r '.success // false' "$resp" 2>/dev/null || echo false)"
err="$(jq -r '.error // empty' "$resp" 2>/dev/null || true)"
msg="$(jq -r '.msg // empty' "$resp" 2>/dev/null || true)"

# A queued start: Vast accepted the state change but the host GPU isn't free
# right now ("resources_unavailable" / "...state change queued"). This is NOT a
# rejection — the box will start when a GPU frees up, so fall through to the
# poll loop with a longer timeout + a relaxed trap window instead of bailing and
# telling the user to destroy+re-rent a box that's merely waiting in queue.
queued=0
if [[ "$success" != "true" ]]; then
  if [[ "$err" == "resources_unavailable" || "$msg" == *"queued"* ]]; then
    queued=1
    echo ">>> start queued by Vast (host GPU busy); will start when a GPU frees up. (${err}: ${msg})" >&2
  else
    echo "Start request rejected: $(jq -c '{error:.error, msg:.msg}' "$resp" 2>/dev/null || cat "$resp")" >&2
    exit 1
  fi
fi

echo ">>> waiting for instance ${instance_id} to reach 'running'..." >&2
poll_args=(--instance-id "$instance_id" --vast-api-url "$vast_api_url")
if [[ "$queued" -eq 1 ]]; then
  # A queued start can wait several minutes for a GPU; relax the poll window.
  poll_args+=(--queued --timeout 1800)
else
  poll_args+=(--timeout "$timeout_sec")
fi
exec scripts/vast_instance_info.sh "${poll_args[@]}"