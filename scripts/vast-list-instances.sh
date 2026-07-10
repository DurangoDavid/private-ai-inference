#!/usr/bin/env bash
# =============================================================================
# scripts/vast-list-instances.sh — non-interactive list of your Vast instances.
#
#   vast-list-instances.sh                 # list all (table)
#   vast-list-instances.sh --running       # only running instances
#   vast-list-instances.sh --label <name>  # only instances matching a label/identity
#   vast-list-instances.sh --json          # raw normalized JSON (full records)
#
# The repo's list-instances.sh is the INTERACTIVE connect flow; this is the
# non-interactive list-only variant (no connect, no spend prompt) for scripts,
# cron, and the watcher's dry-run. Delegates to vast_list_instances_json.sh
# (the proven v1 /api/v1/instances/ helper + vast_normalize_instances.jq).
#
# Env: VAST_API_KEY (required, never echoed), VAST_API_URL (default
# console.vast.ai). Exit 0 (empty list is not an error).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

only_running=0
label=""
json=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --running) only_running=1; shift ;;
    --label) label="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env) — never logged}"

helper="${VAST_INSTANCES_HELPER:-scripts/vast_list_instances_json.sh}"
instances_json="$("$helper")"

if [[ "$json" == "1" ]]; then
  printf '%s' "$instances_json" | jq -c '.instances[]'
  exit 0
fi

# Optional filters (running gate + identity match, same rule as
# vast-pick-active-gpu.sh). --label with no value -> all.
count="$(printf '%s' "$instances_json" | jq -r --argjson running "$only_running" --arg label "$label" '
  [(.instances // [])[]
    | select(($running == 0) or ((.actual_status // "") == "running"))
    | select(($label == "") or ((.label // "") | test($label)) or ((.image_uuid // "") | test($label)))
  ] | length')"

if [[ "$count" == "0" ]]; then
  echo "No Vast.ai instances match." >&2
  exit 0
fi

echo "Vast.ai instances (${count}):"
printf '%-10s %-22s %-10s %-16s %-8s %-7s %s\n' "ID" "LABEL" "STATUS" "IP" "SSH" "$/hr" "GPU"
echo "---------------------------------------------------------------------------------------------------"
printf '%s' "$instances_json" | jq -r --argjson running "$only_running" --arg label "$label" '
  [(.instances // [])[]
    | select(($running == 0) or ((.actual_status // "") == "running"))
    | select(($label == "") or ((.label // "") | test($label)) or ((.image_uuid // "") | test($label)))
  ][]
  | [ (.id//"-"), (.label//"-"), (.actual_status//"-"), (.public_ipaddr//"-"),
      (.ssh_host_port//"-"), (.dph_total//0), (.gpu_name//"-") ]
  | @tsv' | awk -F'\t' '{printf "%-10s %-22s %-10s %-16s %-8s %-7.2f %s\n", $1,$2,$3,$4,$5,$6,$7}'