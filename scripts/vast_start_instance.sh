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
curl -fsS --request PUT \
  --url "${vast_api_url%/}/api/v0/instances/${instance_id}/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{"state":"running"}' > "$resp"
if [[ "$(jq -r '.success // false' "$resp")" != "true" ]]; then
  echo "Start request rejected: $(jq -c '{error:.error, msg:.msg}' "$resp" 2>/dev/null || cat "$resp")" >&2
  exit 1
fi

echo ">>> waiting for instance ${instance_id} to reach 'running'..." >&2
exec scripts/vast_instance_info.sh --instance-id "$instance_id" --vast-api-url "$vast_api_url" --timeout "$timeout_sec"