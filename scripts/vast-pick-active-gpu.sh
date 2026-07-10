#!/usr/bin/env bash
# =============================================================================
# scripts/vast-pick-active-gpu.sh — pick the best active Vast GPU for the tunnel.
#
#   vast-pick-active-gpu.sh                 # print compact pick line (or "none")
#   vast-pick-active-gpu.sh --json          # print the normalized pick record (JSON)
#   vast-pick-active-gpu.sh --dry-run       # human dry-run block + suggested command
#   vast-pick-active-gpu.sh --label <name>  # override VAST_INSTANCE_LABEL
#   vast-pick-active-gpu.sh --match-any     # override VAST_INSTANCE_MATCH_ANY=1
#
# Fetches the account's instances via scripts/vast_list_instances_json.sh (the
# proven v1 /api/v1/instances/ helper + vast_normalize_instances.jq), filters to
# RUNNING boxes that look like ours, and picks the best candidate.
#
# MATCH RULE (handles a real-world untagged box — Vast instances often have no
# label set). An instance matches if ANY of:
#   - label == VAST_INSTANCE_LABEL (default "private-ai-gpu"), OR
#   - image_uuid contains VAST_INSTANCE_LABEL (fresh GPUs launched from the
#     private-ai-gpu image/template carry it in the image name), OR
#   - VAST_INSTANCE_MATCH_ANY=1 (default 0; grab the account's single running
#     GPU for an operator who hasn't tagged — OFF by default so only explicitly
#     tagged boxes are selected).
# The actual_status=="running" gate runs BEFORE the identity match: an exited /
# offline box is never selected even if tagged (don't tunnel to a down box).
#
# SELECTION among matches: highest reliability → most total VRAM
# (gpu_ram × num_gpus) → lowest $/hr (dph_total).
#
# Env: VAST_API_KEY (required, never echoed), VAST_INSTANCE_LABEL (default
# private-ai-gpu), VAST_INSTANCE_MATCH_ANY (default 0), VAST_API_URL (default
# https://console.vast.ai). Exit 0 always (no candidate is not an error — the
# caller decides what to do); a real API/auth failure exits non-zero.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

label="${VAST_INSTANCE_LABEL:-private-ai-gpu}"
match_any="${VAST_INSTANCE_MATCH_ANY:-0}"
mode="compact"   # compact | json | dryrun

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --match-any) match_any=1; shift ;;
    --json) mode="json"; shift ;;
    --dry-run) mode="dryrun"; shift ;;
    -h|--help) sed -n '3,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env) — never logged}"

# Fetch + normalize. vast_list_instances_json.sh prints
# {"success":true,"instances":[<normalized>, ...]} (instances:[] if none).
# VAST_INSTANCES_HELPER lets tests stub the fetcher without touching the real one.
helper="${VAST_INSTANCES_HELPER:-scripts/vast_list_instances_json.sh}"
instances_json="$("$helper")"

# Filter to running + identity match, then pick best. jq builds a compact pick
# record. Uses ONLY structured fields — no eval of any Vast metadata string.
pick="$(printf '%s' "$instances_json" | jq -c '
  def vram_total: ((.gpu_ram // 0) * ((.num_gpus // 1)));
  [(.instances // [])[]
    | select((.actual_status // "") == "running")
    | select(
        ($match_any == 1)
        or ((.label // "") | test($label))
        or ((.image_uuid // "") | test($label))
      )
  ]
  | sort_by(
      -(.reliability // 0),
      -vram_total,
      (.dph_total // 999999)
    )
  | .[0]
  | if . == null then null
    else {
        instance_id: .id,
        label: (.label // ""),
        status: .actual_status,
        host: .public_ipaddr,
        ssh_port: .ssh_host_port,
        gpu: (.gpu_name // "n/a"),
        num_gpus: (.num_gpus // 1),
        vram_gb: (((.gpu_ram // 0) / 1024) | (. * 10 | round / 10)),
        vram_total_gb: ((vram_total / 1024) | (. * 10 | round / 10)),
        reliability: (.reliability // null),
        dph: .dph_total,
        image_uuid: (.image_uuid // ""),
        host_id: (.host_id // null)
      }
    end
' --arg label "$label" --argjson match_any "$match_any")"

if [[ "$pick" == "null" ]]; then
  echo "no running instance matching '${label}'" >&2
  echo "null"
  exit 0
fi

case "$mode" in
  json)
    printf '%s\n' "$pick"
    ;;
  dryrun)
    id="$(printf '%s' "$pick" | jq -r '.instance_id')"
    host="$(printf '%s' "$pick" | jq -r '.host')"
    port="$(printf '%s' "$pick" | jq -r '.ssh_port')"
    gpu="$(printf '%s' "$pick" | jq -r '.gpu')"
    vram="$(printf '%s' "$pick" | jq -r '.vram_gb')"
    status="$(printf '%s' "$pick" | jq -r '.status')"
    echo "selected instance: ${id}"
    echo "host: ${host}"
    echo "ssh_port: ${port}"
    echo "gpu: ${gpu}"
    echo "vram: ${vram} GB"
    echo "status: ${status}"
    # The suggested command is rendered by the sibling helper for one source of
    # truth. Dry-run is non-network, so VAST_API_KEY is irrelevant there.
    scripts/vast-render-fix-command.sh --instance-json <(printf '%s' "$pick")
    ;;
  compact)
    # One line: id  host:port  gpu  vram  status  (easy to grep/pipe).
    printf '%s\n' "$pick" | jq -r '
      "instance \(.instance_id)  \(.host):\(.ssh_port)  \(.gpu)  \(.vram_gb)GB  \(.status)  $\(.dph // "?")/hr"'
    ;;
esac