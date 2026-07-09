#!/usr/bin/env bash
# List your existing Vast.ai instances from the API and (optionally) connect
# the CPU-side tunnel to one — so you can reuse a dormant/active server instead
# of renting a new one. No Terraform, no provisioning: just list + connect.
#
#   list-instances.sh                       # list, then interactively pick one to connect
#   list-instances.sh --list-only           # list, don't connect
#   list-instances.sh --connect <id>        # connect straight to instance <id>
#   list-instances.sh --connect <id> --ssh-key ~/.ssh/vast_ed25519
#
# Requires VAST_API_KEY in the environment. Uses PRIVATE_AI_SSH_KEY (or --ssh-key)
# for the tunnel. Ollama must already be running on the chosen box (this script
# does not install it — use scripts/deploy.sh to provision a fresh box).
set -euo pipefail
cd "$(dirname "$0")/.."

vast_api_url="${VAST_API_URL:-https://console.vast.ai}"
ssh_key="${PRIVATE_AI_SSH_KEY:-}"
mode="interactive"   # interactive | list-only | connect
connect_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-only) mode="list-only"; shift ;;
    --connect) mode="connect"; connect_id="$2"; shift 2 ;;
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --vast-api-url) vast_api_url="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env)}"

# jq: per instance, extract the SSH host port (container port 22) tolerating the
# common Vast `ports` shapes (array of host-port strings, or objects with HostPort).
extract_ssh='
def sshport:
  (.ports["22"] // .ports["22/tcp"]) |
  if . == null then null
  elif (type == "array") then .[0]
  elif (type == "object") then (.HostPort // (.[0].HostPort // null))
  else . end;
{ id, label, status:.actual_status, ip:.public_ipaddr,
  ssh_host_port:(sshport), dph:.dph_total,
  gpu:.gpu_name, gpus:.num_gpus, gpu_ram_mb:.gpu_ram, cpu_ram:.cpu_ram, disk_gb:.disk_space }
'

resp="$(mktemp)"
curl -fsS \
  --request GET \
  --url "${vast_api_url%/}/api/v0/instances/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  > "$resp"

count="$(jq '.instances | length' "$resp")"
if [[ "$count" -eq 0 || "$count" == "null" ]]; then
  echo "No Vast.ai instances found on this account." >&2
  exit 0
fi

instances_json="$(jq -c '.instances[] | '"$extract_ssh" "$resp")"

echo "Vast.ai instances on this account (${count}):"
printf '%-10s %-22s %-10s %-16s %-8s %-7s %s\n' "ID" "LABEL" "STATUS" "IP" "SSH" "$/hr" "GPU"
echo "---------------------------------------------------------------------------------------------------"
ids=()
i=1
while IFS= read -r line; do
  id="$(printf '%s' "$line" | jq -r '.id')"
  label="$(printf '%s' "$line" | jq -r '.label // "-"')"
  status="$(printf '%s' "$line" | jq -r '.status // "-"')"
  ip="$(printf '%s' "$line" | jq -r '.ip // "-"')"
  sshp="$(printf '%s' "$line" | jq -r '.ssh_host_port // "-"')"
  dph="$(printf '%s' "$line" | jq -r '.dph // 0' | awk '{printf "%.2f", $1}')"
  gpu="$(printf '%s' "$line" | jq -r '.gpu // "-"')"
  printf '%-10s %-22s %-10s %-16s %-8s %-7s %s\n' "$id" "$label" "$status" "$ip" "$sshp" "$dph" "$gpu"
  ids+=("$id")
  i=$((i+1))
done <<< "$instances_json"
echo

if [[ "$mode" == "list-only" ]]; then
  exit 0
fi

# Choose an instance to connect to.
if [[ "$mode" == "connect" ]]; then
  chosen="$connect_id"
  if ! printf '%s\n' "${ids[@]}" | grep -qx "$chosen"; then
    echo "Instance id ${chosen} not found in your instances." >&2
    exit 1
  fi
else
  echo "Enter the ID of the instance to connect the tunnel to (blank to abort):"
  read -r chosen
  [[ -n "$chosen" ]] || { echo "Aborted."; exit 0; }
  if ! printf '%s\n' "${ids[@]}" | grep -qx "$chosen"; then
    echo "Not a valid instance id for this account." >&2
    exit 1
  fi
fi

# Pull the chosen instance's ip + ssh port fresh.
chosen_json="$(printf '%s\n' "$instances_json" | jq -r --arg id "$chosen" 'select(.id == ($id|tonumber))')"
ip="$(printf '%s' "$chosen_json" | jq -r '.ip // empty')"
ssh_port="$(printf '%s' "$chosen_json" | jq -r '.ssh_host_port // empty')"
if [[ -z "$ip" || "$ip" == "null" || -z "$ssh_port" || "$ssh_port" == "null" ]]; then
  echo "Could not get ip/ssh port for instance ${chosen} (is it running?)." >&2
  echo "Raw: $chosen_json" >&2
  exit 1
fi
echo "Connecting tunnel to instance ${chosen} at ${ip}:${ssh_port} ..."

# Stand up the tunnel.
scripts/setup-tunnel.sh "$ip" "$ssh_port" "$ssh_key"

# Test through the tunnel.
echo "Testing through the tunnel..."
sleep 3
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "Tunnel up, but /api/tags not reachable on 127.0.0.1:11434." >&2
  echo "Is Ollama actually running on the box? This script does NOT install it." >&2
  echo "If the box has no Ollama, provision a fresh one with: scripts/deploy.sh" >&2
  exit 1
fi
echo "Ollama reachable. Models on the box:"
curl -s http://127.0.0.1:11434/api/tags | jq -r '.models | map("  - " + .name) | .[]' 2>/dev/null || true
echo
echo "Point the Local LLM Hub CPU VM at:  OLLAMA_BASE_URL=http://127.0.0.1:11434"
echo "                                  (container: http://host.docker.internal:11434)"