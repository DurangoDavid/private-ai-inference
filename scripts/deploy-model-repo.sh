#!/usr/bin/env bash
# Deploy an external model-loading repo onto a running Vast.ai box over SSH,
# then run its entrypoint command (e.g. ./install.sh). Used when
# var.model_repo_url is set, so the onstart defers model pulling to this repo.
#
# Auth to clone:
#   * If --model-repo-key <path> is given (a GitHub deploy key, read-only and
#     repo-scoped), the private key is written to ~/.ssh/id_ed25519_deploy on the
#     box (mode 600), ~/.ssh/config is set to use it for github.com, and the repo
#     URL is normalized to the git@github.com SSH form before cloning. Use this
#     for a PRIVATE GPU repo.
#   * If no key is given, the repo is cloned as-is over HTTPS (only works if the
#     repo is public).
#
# The private key is NEVER committed to this repo — it is read from a local
# gitignored file and shipped to the box over the existing SSH connection.
#
#   deploy-model-repo.sh --ip <ip> --port <ssh-port> --repo <git-url> \
#                       [--ssh-key <path>] [--ref <ref>] [--cmd "<command>"] \
#                       [--model-repo-key <path-to-github-deploy-key>]
set -euo pipefail

ip=""
ssh_port=""
ssh_key=""
repo=""
ref="main"
cmd=""
repo_key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) ip="$2"; shift 2 ;;
    --port) ssh_port="$2"; shift 2 ;;
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --cmd) cmd="$2"; shift 2 ;;
    --model-repo-key) repo_key="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ip" || -z "$ssh_port" || -z "$repo" ]]; then
  echo "--ip, --port, --repo are required." >&2
  exit 2
fi

ssh_base=(ssh -p "$ssh_port" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
[[ -n "$ssh_key" ]] && ssh_base+=(-i "$ssh_key")

echo ">>> deploying model repo onto ${ip}:${ssh_port}"
echo "    repo: ${repo}   ref: ${ref}   cmd: ${cmd:-(none)}"

# Normalize an https://github.com/<owner>/<repo>(.git) URL to the SSH form the
# deploy key can authenticate, so users can paste the HTTPS URL from GitHub.
clone_url="$repo"
if [[ -n "$repo_key" && "$repo" == https://github.com/* ]]; then
  p="${repo#https://github.com/}"
  p="${p%.git}"
  clone_url="git@github.com:${p}.git"
  echo "    using deploy key; normalized URL -> ${clone_url}"
fi

# Ship the deploy private key to the box (read locally, write remotely, never
# echoed to logs). Must be generated without a passphrase so the unattended
# clone works.
if [[ -n "$repo_key" ]]; then
  if [[ ! -f "$repo_key" ]]; then
    echo "Deploy key not found at: ${repo_key}" >&2
    echo "Generate one with: scripts/new-deploy-key.sh ~/.ssh/private-ai-gpu_deploy_ed25519" >&2
    exit 1
  fi
  echo "    shipping deploy key to the box (it stays on the box only)..."
  "${ssh_base[@]}" "root@${ip}" "mkdir -p ~/.ssh && cat > ~/.ssh/id_ed25519_deploy && chmod 600 ~/.ssh/id_ed25519_deploy" < "$repo_key"
fi

# Run a heredoc on the remote box: install git if needed, configure ssh for
# github.com when a deploy key is in play, clone the repo, checkout ref, run cmd.
"${ssh_base[@]}" "root@${ip}" "bash -s" -- "$clone_url" "$ref" "$cmd" "$repo_key" <<REMOTE
set -euo pipefail
clone_url="\$1"; ref="\$2"; cmd="\$3"; repo_key="\$4"

if ! command -v git >/dev/null 2>&1; then
  echo "installing git on the box..."
  apt-get update && apt-get install -y git
fi

if [ -n "\$repo_key" ]; then
  # Trust github.com's host key, then pin our deploy key for it.
  ssh-keygen -F github.com >/dev/null 2>&1 || ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true
  cat > ~/.ssh/config <<CFG
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_deploy
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
CFG
  chmod 600 ~/.ssh/config
fi

rm -rf /workspace/model-loader
echo "cloning \${clone_url} (ref \${ref}) -> /workspace/model-loader"
git clone --depth 1 --branch "\${ref}" "\${clone_url}" /workspace/model-loader
cd /workspace/model-loader
if [ -n "\$cmd" ]; then
  echo "running: \$cmd"
  \$cmd
else
  echo "(no --cmd given; repo cloned only)"
fi
REMOTE

echo ">>> model repo deployed. If install.sh pulls models, deploy.sh now waits for them in /api/tags."