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
yes=0   # --yes / VAST_CONFIRM_START=1 skips the start-a-stopped-box spend prompt

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-only) mode="list-only"; shift ;;
    --connect) mode="connect"; connect_id="$2"; shift 2 ;;
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --vast-api-url) vast_api_url="$2"; shift 2 ;;
    --yes) yes=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "${VAST_CONFIRM_START:-0}" == "1" ]] && yes=1

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env)}"

# Fetch via the current v1 list endpoint (v0 /api/v0/instances/ is deprecated).
instances_json="$(scripts/vast_list_instances_json.sh)"
count="$(printf '%s' "$instances_json" | jq '.instances | length')"

if [[ "$count" -eq 0 ]]; then
  echo "No Vast.ai instances found on this account." >&2
  exit 0
fi

echo "Vast.ai instances on your account (${count}):"
printf '%-10s %-22s %-10s %-16s %-8s %-7s %s\n' "ID" "LABEL" "STATUS" "IP" "SSH" "$/hr" "GPU"
echo "---------------------------------------------------------------------------------------------------"
ids=()
while IFS= read -r line; do
  id="$(printf '%s' "$line" | jq -r '.id')"
  label="$(printf '%s' "$line" | jq -r '.label // "-"')"
  status="$(printf '%s' "$line" | jq -r '.actual_status // "-"')"
  ip="$(printf '%s' "$line" | jq -r '.public_ipaddr // "-"')"
  sshp="$(printf '%s' "$line" | jq -r '.ssh_host_port // "-"')"
  dph="$(printf '%s' "$line" | jq -r '.dph_total // 0' | awk '{printf "%.2f", $1}')"
  gpu="$(printf '%s' "$line" | jq -r '.gpu_name // "-"')"
  printf '%-10s %-22s %-10s %-16s %-8s %-7s %s\n' "$id" "$label" "$status" "$ip" "$sshp" "$dph" "$gpu"
  ids+=("$id")
done < <(printf '%s' "$instances_json" | jq -c '.instances[]')
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
chosen_json="$(printf '%s' "$instances_json" | jq -c --arg id "$chosen" '.instances[] | select(.id == ($id|tonumber))')"
ip="$(printf '%s' "$chosen_json" | jq -r '.public_ipaddr // empty')"
ssh_port="$(printf '%s' "$chosen_json" | jq -r '.ssh_host_port // empty')"
if [[ -z "$ip" || "$ip" == "null" || -z "$ssh_port" || "$ssh_port" == "null" ]]; then
  echo "Could not get ip/ssh port for instance ${chosen} (is it running?)." >&2
  echo "Raw: $chosen_json" >&2
  exit 1
fi

# If the box isn't running, offer to start it (resumes billing at its dph_total).
status="$(printf '%s' "$chosen_json" | jq -r '.actual_status // empty')"
if [[ "$status" != "running" ]]; then
  dph="$(printf '%s' "$chosen_json" | jq -r '.dph_total // "?"')"
  gpu="$(printf '%s' "$chosen_json" | jq -r '.gpu_name // "?"')"
  echo "Instance ${chosen} is not running (status: ${status:-unknown})."
  echo "  Starting it resumes billing at ~${dph} \$/hr (${gpu})."
  if [[ "$yes" == "1" ]]; then
    echo "  --yes/VAST_CONFIRM_START=1 set: starting without prompting." >&2
  elif [[ ! -t 0 ]]; then
    echo "  Non-interactive run: NOT starting (no spend). Start it manually then re-run," >&2
    echo "  or pre-consent: scripts/list-instances.sh --connect ${chosen} --yes (or export VAST_CONFIRM_START=1)." >&2
    exit 1
  else
    read -r -p "  Start it now? [y/N] " start_confirm
    case "$start_confirm" in
      y|Y|yes|YES) ;;
      *) echo "Aborted — nothing started." ; exit 0 ;;
    esac
  fi
  # vast_start_instance.sh execs vast_instance_info.sh, which polls until the
  # box is running AND has an ssh port assigned, then prints the info JSON to
  # stdout (progress goes to stderr, shown live). Capture stdout to a temp file
  # and check the exit code explicitly so a failed start (rejected PUT, or a Vast
  # trap state) is reported clearly instead of misread as "ip/ssh_port not ready".
  start_info_file="$(mktemp)"
  if ! scripts/vast_start_instance.sh --instance-id "$chosen" --vast-api-url "$vast_api_url" > "$start_info_file"; then
    rm -f "$start_info_file"
    echo "Failed to start instance ${chosen} — see the messages above (rejected PUT, or a Vast trap state)." >&2
    echo "If it's stuck in exited/offline, destroy it and re-rent: run.sh -> 'new' (or scripts/deploy.sh)." >&2
    exit 1
  fi
  ip="$(jq -r '.public_ipaddr // empty' "$start_info_file")"
  ssh_port="$(jq -r '.ssh_host_port // empty' "$start_info_file")"
  rm -f "$start_info_file"
  if [[ -z "$ip" || "$ip" == "null" || -z "$ssh_port" || "$ssh_port" == "null" ]]; then
    for _ in $(seq 1 12); do  # ~1 min extra grace for the port to be mapped
      fresh="$(scripts/vast_list_instances_json.sh --id "$chosen")"
      ip="$(printf '%s' "$fresh" | jq -r '.instances[0].public_ipaddr // empty')"
      ssh_port="$(printf '%s' "$fresh" | jq -r '.instances[0].ssh_host_port // empty')"
      [[ -n "$ip" && "$ip" != "null" && -n "$ssh_port" && "$ssh_port" != "null" ]] && break
      sleep 5
    done
  fi
  if [[ -z "$ip" || "$ip" == "null" || -z "$ssh_port" || "$ssh_port" == "null" ]]; then
    echo "Instance started but ip/ssh_port not available yet; re-run connect shortly." >&2
    exit 1
  fi
fi

echo "Connecting tunnel to instance ${chosen} at ${ip}:${ssh_port} ..."

# Stand up the tunnel.
scripts/setup-tunnel.sh "$ip" "$ssh_port" "$ssh_key"

# Test through the tunnel (retry — a freshly-started box needs boot time for
# the tunnel to establish and Ollama to come back up).
echo "Testing through the tunnel..."
ok=0
for _ in $(seq 1 24); do  # ~2 min
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [[ $ok -ne 1 ]]; then
  echo "Tunnel up, but /api/tags not reachable on 127.0.0.1:11434 after ~2 min." >&2
  echo "Is Ollama actually running on the box? This script does NOT install it." >&2
  echo "If the box has no Ollama, provision a fresh one with: scripts/deploy.sh" >&2
  exit 1
fi
echo "Ollama reachable. Models on the box:"
curl -s http://127.0.0.1:11434/api/tags | jq -r '.models | map("  - " + .name) | .[]' 2>/dev/null || true
echo
echo "Point the Local LLM Hub CPU VM at:  OLLAMA_BASE_URL=http://127.0.0.1:11434"
echo "                                  (container: http://host.docker.internal:11434)"