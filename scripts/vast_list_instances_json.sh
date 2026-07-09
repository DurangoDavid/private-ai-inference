#!/usr/bin/env bash
# Current Vast.ai instance fetcher. Vast deprecated /api/v0/instances/ (it
# returns 410 for valid API keys) and there is no v1 single-instance route, so
# this hits the v1 LIST endpoint (/api/v1/instances/) with keyset pagination and
# (optionally) an `id` filter, then normalizes each instance to a stable shape.
# Every other script in this repo that needs instance data calls this helper
# so the v1/pagination logic lives in one place.
#
#   vast_list_instances_json.sh                 # all instances (paginated)
#   vast_list_instances_json.sh --id 44255872   # one instance (v1 list, id filter)
#
# Env: VAST_API_KEY (required), VAST_API_URL (default https://console.vast.ai)
# Stdout: {"success":true,"instances":[<normalized>, ...]}  (instances:[] if none)
set -euo pipefail
cd "$(dirname "$0")/.."

vast_api_url="${VAST_API_URL:-https://console.vast.ai}"
id_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) id_filter="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env)}"

# v1 lets us select exactly the columns we use (unknown columns -> null).
cols='["id","label","actual_status","cur_state","intended_status","public_ipaddr","ssh_host","ssh_port","ports","dph_total","gpu_name","num_gpus","gpu_ram","cpu_ram","disk_space","reliability2","verification","geolocation","datacenter","image_uuid","host_id"]'

if [[ -n "$id_filter" ]]; then
  filters="$(jq -nc --argjson id "${id_filter}" '{id:{eq:$id}}')"
else
  filters='{}'
fi

raw="$(mktemp)"
lines="$(mktemp)"
trap 'rm -f "$raw" "$lines"' EXIT

pages=0
after=""
while [[ $pages -lt 40 ]]; do
  pages=$((pages + 1))
  args=(--data-urlencode "limit=25" --data-urlencode "select_cols=$cols" --data-urlencode "select_filters=$filters")
  [[ -n "$after" ]] && args+=(--data-urlencode "after_token=$after")
  if ! curl -fsS -G \
    --url "${vast_api_url%/}/api/v1/instances/" \
    --header "Authorization: Bearer ${VAST_API_KEY}" \
    --header "Content-Type: application/json" \
    "${args[@]}" > "$raw"; then
    echo "v1 instances request failed (auth or network)." >&2
    exit 1
  fi
  if [[ "$(jq -r '.success // false' "$raw")" != "true" ]]; then
    echo "v1 instances request rejected: $(jq -c '{error:.error, msg:.msg}' "$raw")" >&2
    exit 1
  fi
  jq -c '.instances[]' "$raw" >> "$lines" 2>/dev/null || true
  after="$(jq -r '.next_token // empty' "$raw")"
  [[ -z "$after" ]] && break
done

if [[ ! -s "$lines" ]]; then
  echo '{"success":true,"instances":[]}'
  exit 0
fi

jq -s -f scripts/vast_normalize_instances.jq "$lines"