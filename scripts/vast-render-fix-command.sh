#!/usr/bin/env bash
# =============================================================================
# scripts/vast-render-fix-command.sh — render the CPU reconnect/fix command for
# a Vast instance record. Pure formatting — NO network, NO VAST_API_KEY needed.
#
#   echo '<record>' | vast-render-fix-command.sh
#   vast-render-fix-command.sh --instance-json <file>
#   vast-render-fix-command.sh --customer jane --key /root/.ssh/vast_ed25519
#   vast-render-fix-command.sh --script reconnect-gpu-tunnel.sh   # just one
#
# Accepts either a compact pick record from vast-pick-active-gpu.sh
# ({instance_id,host,ssh_port,...}) OR a raw normalized instance from
# vast_list_instances_json.sh ({public_ipaddr,ssh_host_port,...}).
#
# Args:
#   --customer <slug>   default david (env GPU_DEFAULT_CUSTOMER)
#   --key <path>        default /root/.ssh/vast_ed25519 (env GPU_TUNNEL_KEY)
#   --script <name>     reconnect-gpu-tunnel.sh | fix.sh | both (default both)
#   --instance-json <f> read the record from a file instead of stdin
#
# Prints:
#   suggested fix command:
#     sudo sh scripts/fix.sh --gpu-host <host> --gpu-ssh-port <port> --key <key> --customer <slug>
#     sudo sh scripts/reconnect-gpu-tunnel.sh --gpu-host <host> --gpu-ssh-port <port> --key <key> --customer <slug>
# =============================================================================
set -euo pipefail

customer="${GPU_DEFAULT_CUSTOMER:-david}"
key="${GPU_TUNNEL_KEY:-/root/.ssh/vast_ed25519}"
script="both"
instance_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer) customer="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --script) script="$2"; shift 2 ;;
    --instance-json) instance_file="$2"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$instance_file" ]]; then
  record="$(cat "$instance_file")"
else
  record="$(cat)"
fi

# Tolerant extraction: compact pick record (.host/.ssh_port) OR raw normalized
# instance (.public_ipaddr/.ssh_host_port). Empty record -> clear error.
if [[ -z "${record// }" ]]; then
  echo "vast-render-fix-command: no instance record on stdin (pipe one, or use --instance-json <file>)." >&2
  exit 2
fi

host="$(printf '%s' "$record" | jq -r '.host // .public_ipaddr // empty')"
port="$(printf '%s' "$record" | jq -r '.ssh_port // .ssh_host_port // empty')"

if [[ -z "$host" || "$host" == "null" || -z "$port" || "$port" == "null" ]]; then
  echo "vast-render-fix-command: could not read host/ssh_port from the record." >&2
  echo "  record: $record" >&2
  exit 2
fi

print_cmd() {  # $1 = script name
  echo "  sudo sh scripts/$1 --gpu-host $host --gpu-ssh-port $port --key $key --customer $customer"
}

echo "suggested fix command:"
case "$script" in
  both)
    print_cmd fix.sh
    print_cmd reconnect-gpu-tunnel.sh
    ;;
  fix.sh) print_cmd fix.sh ;;
  reconnect-gpu-tunnel.sh) print_cmd reconnect-gpu-tunnel.sh ;;
  *) echo "vast-render-fix-command: --script must be fix.sh, reconnect-gpu-tunnel.sh, or both (got '$script')." >&2; exit 2 ;;
esac