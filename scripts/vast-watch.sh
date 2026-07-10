#!/usr/bin/env bash
# =============================================================================
# scripts/vast-watch.sh — one-shot Vast GPU watcher entry point (public repo).
#
#   vast-watch.sh                 # print the normalized pick record (JSON) to stdout
#   vast-watch.sh --dry-run       # human dry-run block + suggested command
#   vast-watch.sh --label <name>  # override VAST_INSTANCE_LABEL
#   vast-watch.sh --match-any     # override VAST_INSTANCE_MATCH_ANY=1
#
# Runs ONCE (not a loop — the live loop is the CPU repo's watch-vast-gpu.sh /
# private-ai-vast-watcher.service). This keeps the public script composable and
# unit-testable: fetch → filter → pick → print.
#
# --dry-run prints exactly the operator-facing format:
#   selected instance: 44370095
#   host: 75.26.236.5
#   ssh_port: 40897
#   gpu: RTX PRO 6000 WS
#   vram: 95.6 GB
#   status: running
#   suggested fix command:
#     sudo sh scripts/fix.sh --gpu-host 75.26.236.5 --gpu-ssh-port 40897 ...
#
# No candidate -> a clear "no running instance matching <label>" line (NOT an
# error; exit 0). A real API/auth failure exits non-zero. VAST_API_KEY is read
# from env and NEVER logged.
#
# Env: VAST_API_KEY (required), VAST_INSTANCE_LABEL (default private-ai-gpu),
# VAST_INSTANCE_MATCH_ANY (default 0), VAST_API_URL (default console.vast.ai),
# GPU_DEFAULT_CUSTOMER (default david), GPU_TUNNEL_KEY (default
# /root/.ssh/vast_ed25519).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

dry_run=0
passthrough=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
    *) passthrough+=("$1"); shift ;;
  esac
done

if [[ "$dry_run" == "1" ]]; then
  exec scripts/vast-pick-active-gpu.sh --dry-run "${passthrough[@]:-}"
else
  # Default: emit the normalized pick record (JSON) to stdout for machine
  # consumption. "null" (no candidate) is a valid, non-error output.
  exec scripts/vast-pick-active-gpu.sh --json "${passthrough[@]:-}"
fi