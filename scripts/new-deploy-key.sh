#!/usr/bin/env bash
# Generate a read-only GitHub deploy key for the GPU gateway repo.
#
#   new-deploy-key.sh [path/to/key]
#
# Writes:
#   - <path>         the PRIVATE key  (gitignore this; NEVER commit it)
#   - <path>.pub     the PUBLIC key   (paste into GitHub repo Settings → Deploy
#                                      keys; leave "Allow write access" OFF)
# Then prints the public key and the .env line to point at the private key.
#
# A deploy key is repo-scoped and read-only — the right tool for "let a freshly
# rented Vast box clone one private repo." Generate it ONCE, reuse it on every
# box (deploy-model-repo.sh ships the private half to each box at runtime).
set -euo pipefail

out="${1:-$HOME/.ssh/private-ai-gpu_deploy_ed25519}"
if [[ -e "$out" || -e "${out}.pub" ]]; then
  echo "Refusing to overwrite existing key at ${out}(.pub)." >&2
  echo "Delete it first or pass a different path." >&2
  exit 1
fi
mkdir -p "$(dirname "$out")"

# No passphrase (-N ""): the clone runs unattended on the box.
ssh-keygen -t ed25519 -N "" -C "private-ai-inference deploy key" -f "$out" >/dev/null
chmod 600 "$out"
chmod 644 "${out}.pub"

echo "Private key written to:  ${out}   (gitignore this; never commit)"
echo
echo "=== PUBLIC key — paste into GitHub: private-ai-gpu → Settings → Deploy keys ==="
echo "    (leave \"Allow write access\" OFF so it is read-only)"
echo "------------------------------------------------------------------------"
cat "${out}.pub"
echo "------------------------------------------------------------------------"
echo
echo "Then in .env:"
echo "  PRIVATE_AI_GPU_DEPLOY_KEY=${out}"
echo "  PRIVATE_AI_GPU_REPO=https://github.com/DurangoDavid/private-ai-gpu.git"
echo "  PRIVATE_AI_GPU_REPO_CMD=./install.sh"