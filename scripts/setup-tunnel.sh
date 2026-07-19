#!/usr/bin/env bash
# Stand up the CPU-side SSH tunnel to the Vast.ai Ollama GPU box as a
# self-contained Docker container — mirrors the proven method in
# ../private-ai/scripts/setup-vast-tunnel.sh (and fix.sh's tunnel_recreate):
#
#   setup-tunnel.sh <host> <ssh-port> [ssh-key]
#
# Forwards the CPU host's 0.0.0.0:11434 -> <host>:127.0.0.1:11434 (Ollama on the
# box is loopback-only). The app/gateway then points OLLAMA_BASE_URL at
# http://127.0.0.1:11434 (bare metal) or http://host.docker.internal:11434
# (in a container) — the same value the private-ai CPU repo's setup-vast-tunnel.sh produces,
# so no app-side change is needed.
#
# The tunnel runs in an `alpine:3.20` container that `apk add`s openssh-client +
# autossh + curl AT RUNTIME. Nothing is installed on the host, and nothing is
# baked into any image — the private-ai app image needs no autossh, and the CPU
# VM base image needs no autossh. Docker auto-pulls alpine:3.20 on first run.
# Idempotent: re-running tears down the old container and brings up a fresh one.
#
# Requires `docker` (not host `autossh`). Env: PRIVATE_AI_SSH_KEY (or --ssh-key).
set -euo pipefail

host="${1:-}"
ssh_port="${2:-}"
ssh_key="${3:-${PRIVATE_AI_SSH_KEY:-$HOME/.ssh/vast_ed25519}}"

if [[ -z "$host" || -z "$ssh_port" ]]; then
  echo "Usage: setup-tunnel.sh <host> <ssh-port> [ssh-key]" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH. The tunnel runs in an alpine container (autossh is" >&2
  echo "installed inside it at runtime — no host autossh, no image bloat). Install Docker" >&2
  echo "and re-run." >&2
  exit 1
fi

# Expand a leading ~/ in the key path.
case "$ssh_key" in "~/"*) ssh_key="${HOME}${ssh_key#\~/}" ;; esac

if [[ -n "$ssh_key" ]]; then
  if [[ ! -f "$ssh_key" ]]; then
    echo "SSH key not found: $ssh_key" >&2
    exit 1
  fi
  # chmod the HOST key 600 (ssh rejects a group/world-readable key). The mount is
  # read-only into the container — no chmod in-container.
  chmod 600 "$ssh_key" 2>/dev/null || true
  [[ -r "$ssh_key" ]] || { echo "SSH key at $ssh_key isn't readable." >&2; exit 1; }
fi

image="${TUNNEL_IMAGE:-alpine:3.20}"
container="private-ai-ollama-tunnel"

echo "=== CPU -> GPU tunnel (alpine autossh container) ==="
echo "  GPU host:  $host:$ssh_port"
echo "  SSH key:   $ssh_key  (mounted read-only at /root/.ssh/vast_ed25519)"
echo "  image:     $image"
echo "  forward:   0.0.0.0:11434 -> $host:127.0.0.1:11434"
echo

# 1. Tear down any existing tunnel container (idempotent re-run).
echo "  [1/3] removing any existing $container..."
docker rm -f "$container" >/dev/null 2>&1 || true

# 2. Create the durable autossh tunnel container.
#    -p 11434:11434          publish on the CPU host as 0.0.0.0:11434 (NOT
#                            127.0.0.1:11434:11434 — app/gateway containers reach
#                            it via host.docker.internal, which can't hit loopback).
#    -v ...:/root/.ssh/vast_ed25519:ro   read-only key mount. No chmod in-container.
#    sh -lc 'apk add ... && autossh ...'  self-contained: alpine installs autossh
#                            at runtime, then runs autossh as the container's PID 1.
#                            The whole autossh command is one single-quoted arg;
#                            $ssh_port + $host are spliced in by closing/reopening
#                            the single quote (both validated: port is numeric, host
#                            is an IP/hostname — no shell-special chars).
#    -M 0 = no monitor port (ServerAlive probes keep it up through NAT), -N forward-only.
#    ExitOnForwardFailure=yes so autossh detects a failed -L bind (e.g. 11434 taken)
#                            and reconnects instead of holding a dead forward.
echo "  [2/3] creating $container..."
docker run -d --name "$container" --restart unless-stopped \
  -p 11434:11434 \
  -v "$ssh_key:/root/.ssh/vast_ed25519:ro" \
  "$image" \
  sh -lc 'apk add --no-cache openssh-client autossh curl && autossh -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -i /root/.ssh/vast_ed25519 -p '"$ssh_port"' -L 0.0.0.0:11434:127.0.0.1:11434 root@'"$host"'"' \
  >/dev/null 2>&1 \
  || { echo "failed to create $container. Is the Docker daemon up + is $image pullable? Try: docker pull $image" >&2; exit 1; }

# 3. Validate the forward reaches the GPU's Ollama.
echo "  [3/3] validating the tunnel..."
ok=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [[ $ok -ne 1 ]]; then
  echo "Tunnel container is up but the forward isn't reaching the GPU yet." >&2
  echo "Check, in order:" >&2
  echo "  1. Tunnel logs (fastest signal):  docker logs --tail 50 $container" >&2
  echo "     - 'Permission denied (publickey)' -> the key's PUBLIC half isn't authorized on the GPU box." >&2
  echo "     - 'Connection refused'/'timed out' -> wrong host or ssh-port (Vast reassigns the SSH port on every swap)." >&2
  echo "     - 'remote port forwarding failed' -> something already bound 11434 on the GPU (pkill ollama there + retry)." >&2
  echo "  2. Is Ollama up + bound to 127.0.0.1:11434 on the box?" >&2
  echo "       ssh -i $ssh_key -p $ssh_port root@$host 'curl -sf http://127.0.0.1:11434/api/version'" >&2
  exit 1
fi
echo "  tunnel UP — host 127.0.0.1:11434: $(curl -fsS http://127.0.0.1:11434/api/version 2>/dev/null || echo '(version unreadable)')"
echo
echo "Point the Local LLM Hub CPU VM at:  OLLAMA_BASE_URL=http://127.0.0.1:11434"
echo "                                  (container: http://host.docker.internal:11434)"
echo "Tunnel container:  $container  (docker restart unless-stopped — autossh auto-reconnects)"
echo "Swap the GPU box later:  scripts/setup-tunnel.sh <new-host> <new-port> $ssh_key"