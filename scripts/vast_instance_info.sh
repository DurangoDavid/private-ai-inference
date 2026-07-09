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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --instance-id) instance_id="$2"; shift 2 ;;
    --vast-api-url) vast_api_url="$2"; shift 2 ;;
    --timeout) timeout_sec="$2"; shift 2 ;;
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

mkdir -p "$state_dir"
info_file="$state_dir/instance_info.json"

# jq filter: extract the SSH host port from the Vast `ports` map, tolerating the
# common shapes (array of host-port strings, or objects with HostPort).
extract='def sshport:
  (.ports["22"] // .ports["22/tcp"]) |
  if . == null then null
  elif (type == "array") then .[0]
  elif (type == "object") then (.HostPort // (.[0].HostPort // null))
  else . end;
{instance_id:.id, status:.actual_status, public_ipaddr:.public_ipaddr, ports:.ports, ssh_host_port:(sshport)}'

deadline=$(( $(date +%s) + timeout_sec ))
last=""
while true; do
  if ! curl -fsS \
    --request GET \
    --url "${vast_api_url%/}/api/v0/instances/${instance_id}/" \
    --header "Authorization: Bearer ${VAST_API_KEY}" \
    > "$state_dir/instance_raw.json" 2>/dev/null; then
    echo "instance not reachable yet (API error); retrying..." >&2
  else
    info="$(jq -c "$extract" "$state_dir/instance_raw.json" 2>/dev/null || true)"
    status="$(printf '%s' "$info" | jq -r '.status // empty' 2>/dev/null || true)"
    if [[ "$status" == "running" ]]; then
      printf '%s\n' "$info" | jq '.' > "$info_file"
      printf '%s\n' "$info"
      echo "Instance ${instance_id} is running." >&2
      exit 0
    fi
    if [[ "$status" != "$last" ]]; then
      echo "instance ${instance_id} status: ${status:-unknown}; waiting for running..." >&2
      last="$status"
    fi
  fi
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "Timed out waiting for instance ${instance_id} to reach 'running' (${timeout_sec}s)." >&2
    [[ -n "$info" ]] && printf '%s\n' "$info" > "$info_file"
    exit 1
  fi
  sleep 10
done