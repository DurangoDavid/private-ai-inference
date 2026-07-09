#!/usr/bin/env bash
# Poll a Vast.ai instance until it is running, then print its public IP + the
# host port mapped to container port 22 (SSH), as JSON. Used by deploy.sh
# between provisioning and standing up the tunnel.
#
# Usage:
#   vast_instance_info.sh --state-dir <dir> [--vast-api-url <url>] [--timeout <sec>]
#   vast_instance_info.sh --instance-id <id>  [--vast-api-url <url>] [--timeout <sec>]
#
# Requires VAST_API_KEY in the environment. Writes instance_info.json into the
# state dir (when --state-dir is given) and prints the same JSON to stdout.
set -euo pipefail

vast_api_url="https://console.vast.ai"
state_dir=""
instance_id=""
timeout_sec=900 # 15 min default
queued=0        # --queued: start was queued by Vast (resources_unavailable); a
               # long 'exited' wait is expected, NOT a trap.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --instance-id) instance_id="$2"; shift 2 ;;
    --vast-api-url) vast_api_url="$2"; shift 2 ;;
    --timeout) timeout_sec="$2"; shift 2 ;;
    --queued) queued=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${VAST_API_KEY:-}" ]]; then
  echo "VAST_API_KEY must be exported." >&2
  exit 1
fi

if [[ -z "$instance_id" ]]; then
  if [[ -z "$state_dir" ]]; then
    echo "Provide --instance-id or --state-dir." >&2
    exit 2
  fi
  instance_id_file="$state_dir/instance_id"
  if [[ ! -s "$instance_id_file" ]]; then
    echo "No instance_id found at ${instance_id_file} (did terraform apply run?)." >&2
    exit 1
  fi
  instance_id="$(tr -d '[:space:]' < "$instance_id_file")"
fi

info_file=""
if [[ -n "$state_dir" ]]; then
  mkdir -p "$state_dir"
  info_file="$state_dir/instance_info.json"
fi

# The v0 single-instance GET (like the v0 list) is deprecated, and v1 has no
# single-instance route. Poll the v1 list filtered by id instead. The helper
# normalizes + precomputes ssh_host_port.
export VAST_API_URL="$vast_api_url"
extract='{instance_id:.id, status:.actual_status, public_ipaddr:.public_ipaddr, ports:.ports, ssh_host_port:.ssh_host_port}'

deadline=$(( $(date +%s) + timeout_sec ))
last=""
info=""
# Trap-state fast-fail. Per the Vast docs, actual_status of exited/unknown/offline
# will NEVER reach 'running' — destroy and retry (i.e. fall through to a fresh
# rent). 'exited' is also the resting state of a deliberately STOPPED box, so it
# gets a grace window (the start PUT takes a few poll cycles to flip it to
# 'loading'); 'offline'/'unknown' are never healthy and fail fast.
trap_grace_exited=120   # sec stuck in 'exited' after we asked it to run
trap_grace_other=30     # sec stuck in 'offline'/'unknown'
# A queued start (resources_unavailable) legitimately sits in 'exited' while
# Vast waits for a GPU to free up — that is NOT a trap. Extend the 'exited'
# grace to the full deadline so we don't tell the user to destroy+re-rent a box
# that's merely queued. 'offline'/'unknown' still fail fast regardless.
[[ "$queued" -eq 1 ]] && trap_grace_exited="$timeout_sec"
stuck_state=""; stuck_since=0
while true; do
  raw="$(scripts/vast_list_instances_json.sh --id "$instance_id" 2>/dev/null || true)"
  one="$(printf '%s' "$raw" | jq -c '.instances[0] // empty' 2>/dev/null || true)"
  if [[ -n "$one" ]]; then
    info="$(printf '%s' "$one" | jq -c "$extract" 2>/dev/null || true)"
    status="$(printf '%s' "$info" | jq -r '.status // empty' 2>/dev/null || true)"
    port="$(printf '%s' "$info" | jq -r '.ssh_host_port // empty' 2>/dev/null || true)"
    # Success requires BOTH 'running' AND an assigned ssh port. On a fresh rent
    # Vast reports status=running before the host port for container 22 is mapped,
    # so returning on 'running' alone hands the caller an empty ssh_host_port and
    # the tunnel setup dies. The port usually lands within seconds of 'running'.
    if [[ "$status" == "running" && -n "$port" && "$port" != "null" ]]; then
      [[ -n "$info_file" ]] && printf '%s\n' "$info" | jq '.' > "$info_file"
      printf '%s\n' "$info"
      echo "Instance ${instance_id} is running (ssh port ${port})." >&2
      exit 0
    fi
    progress="status: ${status:-unknown}"
    [[ "$status" == "running" ]] && progress="status: running; waiting for ssh port..."
    if [[ "$progress" != "$last" ]]; then
      echo "instance ${instance_id} ${progress}" >&2
      last="$progress"
    fi
    # Track how long we've been stuck in a trap state without progress. 'loading'
    # (or any non-trap state) resets the timer; a persistent trap state past its
    # grace means the start/rent didn't take — fail fast so the caller can destroy
    # + re-rent instead of waiting the full timeout.
    case "$status" in
      exited)    grace="$trap_grace_exited" ;;
      offline|unknown) grace="$trap_grace_other" ;;
      *) grace=0 ;;
    esac
    now="$(date +%s)"
    if [[ "$grace" -gt 0 ]]; then
      if [[ "$status" != "$stuck_state" ]]; then
        stuck_state="$status"; stuck_since="$now"
      elif [[ $(( now - stuck_since )) -ge "$grace" ]]; then
        echo "Instance ${instance_id} is stuck in '${status}' (a Vast trap state that never reaches 'running')." >&2
        echo "The start/rent did not take. Destroy it and re-rent a fresh box (run.sh -> 'new', or scripts/deploy.sh)." >&2
        [[ -n "$info" && -n "$info_file" ]] && printf '%s\n' "$info" > "$info_file"
        exit 1
      fi
    else
      stuck_state=""; stuck_since=0
    fi
  else
    echo "instance ${instance_id} not found yet (provisioning or API error); retrying..." >&2
  fi
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "Timed out waiting for instance ${instance_id} to reach 'running' with an ssh port (${timeout_sec}s)." >&2
    if [[ "$queued" -eq 1 ]]; then
      echo "The start was queued (host GPU was busy) and no GPU freed up in time." >&2
      echo "Re-run the connect/deploy in a few minutes — the queued start may still take, or destroy+re-rent if the host is permanently full." >&2
    fi
    [[ -n "$info" && -n "$info_file" ]] && printf '%s\n' "$info" > "$info_file"
    exit 1
  fi
  sleep 10
done