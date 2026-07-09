#!/usr/bin/env bash
# Stand up the CPU-side SSH tunnel to the Vast.ai Ollama GPU box, mirroring
# README1.md's setup-vast-tunnel.sh contract:
#
#   setup-tunnel.sh <host> <ssh-port> [ssh-key]
#
# Forwards the CPU VM's 0.0.0.0:11434 -> <host>:127.0.0.1:11434 (Ollama on the
# box is loopback-only). The CPU app/gateway then points OLLAMA_BASE_URL at
# http://127.0.0.1:11434 (bare metal) or http://host.docker.internal:11434
# (in a container) — the same value README1.md's setup-vast-tunnel.sh produces,
# so no app-side change is needed.
#
# On Linux: writes a systemd unit and enables it. On macOS (dev): runs autossh
# under a launchd plist (best-effort). Requires `autossh` on PATH.
set -euo pipefail

host="${1:-}"
ssh_port="${2:-}"
ssh_key="${3:-${PRIVATE_AI_SSH_KEY:-}}"

if [[ -z "$host" || -z "$ssh_port" ]]; then
  echo "Usage: setup-tunnel.sh <host> <ssh-port> [ssh-key]" >&2
  exit 2
fi

if ! command -v autossh >/dev/null 2>&1; then
  echo "autossh not found. Install it: apt install autossh  (Linux) or brew install autossh (macOS)." >&2
  exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3
  -o ExitOnForwardFailure=yes -N)

if [[ -n "$ssh_key" ]]; then
  if [[ ! -f "$ssh_key" ]]; then
    echo "SSH key not found: $ssh_key" >&2
    exit 1
  fi
  chmod 600 "$ssh_key" 2>/dev/null || true
  ssh_opts+=(-i "$ssh_key")
fi

forward="-L 0.0.0.0:11434:127.0.0.1:11434"
user_host="root@${host}"

uname_s="$(uname -s)"
case "$uname_s" in
  Linux)
    unit="/etc/systemd/system/private-ai-ollama-tunnel.service"
    echo "Writing systemd unit: $unit"
    sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=private-ai-inference Ollama SSH tunnel (CPU -> Vast.ai GPU box)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 ${forward} -p ${ssh_port} ${ssh_opts[*]} ${user_host}
Restart=always
RestartSec=5
Environment=AUTOSSH_GATETIME=0

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now private-ai-ollama-tunnel.service
    echo "Tunnel up. Verify: curl -s http://127.0.0.1:11434/api/tags"
    ;;
  Darwin)
    label="com.private-ai-inference.ollama-tunnel"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    autossh_bin="$(command -v autossh)"
    echo "Writing launchd plist: $plist"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${autossh_bin}</string><string>-M</string><string>0</string>
    <string>${forward}</string><string>-p</string><string>${ssh_port}</string>
EOF
    for o in "${ssh_opts[@]}"; do printf '    <string>%s</string>\n' "$o" >> "$plist"; done
    cat >> "$plist" <<EOF
    <string>${user_host}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict><key>AUTOSSH_GATETIME</key><string>0</string></dict>
</dict></plist>
EOF
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load -w "$plist"
    echo "Tunnel up (launchd). Verify: curl -s http://127.0.0.1:11434/api/tags"
    ;;
  *)
    echo "Unsupported OS: $uname_s. Run manually: autossh -M 0 ${forward} -p ${ssh_port} ${ssh_opts[*]} ${user_host}" >&2
    exit 1
    ;;
esac