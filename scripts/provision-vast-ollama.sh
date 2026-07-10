#!/usr/bin/env bash
# =============================================================================
# scripts/provision-vast-ollama.sh — rent a fresh Vast GPU pre-tagged for the
# CPU watcher.
#
#   provision-vast-ollama.sh [any deploy.sh args...]
#   provision-vast-ollama.sh --models qwen3_6_35b,gemma3_27b,nomic_embed --market-type bid
#
# Thin wrapper over scripts/deploy.sh that bakes in the private-ai-gpu IDENTITY
# so the CPU watcher (private-ai/watch-vast-gpu.sh) can discover the box via the
# Vast API without a manual tag step. The instance label is set at create time
# by Terraform: main.tf sets `label = var.name`, where name =
# format("%s-02d", var.deployment_name, N). So exporting
# TF_VAR_deployment_name=private-ai-gpu labels the box "private-ai-gpu-01",
# which the watcher matches (substring on label/image_uuid — see
# vast-pick-active-gpu.sh). The watcher's VAST_INSTANCE_MATCH_ANY=0 default then
# selects ONLY this tagged box, not random account instances.
#
# All other args pass through to deploy.sh unchanged (it owns the real
# provisioning: terraform render → vast_create_instance.sh rent → wait for
# models → tunnel → test). This wrapper adds NO provisioning logic of its own.
#
# Env: VAST_API_KEY (required by deploy.sh), TF_VAR_deployment_name (default
# private-ai-gpu — override to use a different tag). Anything else deploy.sh
# reads (PRIVATE_AI_SSH_KEY, market type, models, model repo...) is forwarded.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# Default the identity tag. `:` lets an externally-exported value win.
: "${TF_VAR_deployment_name:=private-ai-gpu}"
export TF_VAR_deployment_name

echo "=== provision Vast GPU (tagged '${TF_VAR_deployment_name}') ==="
echo "  The instance will be labeled '${TF_VAR_deployment_name}-01' so the CPU"
echo "  watcher (VAST_INSTANCE_LABEL=${TF_VAR_deployment_name}) discovers it via"
echo "  the Vast API. No GPU-side heartbeat needed."
echo "  Forwarding to deploy.sh: $*"
echo

exec scripts/deploy.sh "$@"