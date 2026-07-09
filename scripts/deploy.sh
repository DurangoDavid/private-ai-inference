#!/usr/bin/env bash
# End-to-end runner that lives on the CPU VM. It:
#   0. (optional) reuses an existing Vast.ai instance instead of renting,
#   1. asks which fleet models to co-host (select-models.sh) + sizes VRAM,
#   2. provisions the Vast.ai GPU box (terraform apply) — by default renting the
#      cheapest offer that has an Ollama template (Ollama preinstalled),
#   3. waits for the instance to reach 'running' + Ollama to come up,
#   3b. (optional) deploys an external model-loading repo onto the box,
#   4. waits for the selected LOCAL models to finish pulling ("takes a while"),
#   5. stands up the SSH tunnel (setup-tunnel.sh) -> CPU 0.0.0.0:11434 -> box 127.0.0.1:11434,
#   6. tests through the tunnel (/api/tags + /api/generate).
#
# Usage:
#   source .env  # VAST_API_KEY, PRIVATE_AI_SSH_KEY
#   scripts/deploy.sh                              # interactive model pick + full flow (Ollama template)
#   scripts/deploy.sh --models qwen3_6_35b,gemma3_27b,nomic_embed
#   scripts/deploy.sh --prefer-existing            # reuse a running instance if one exists, else rent
#   scripts/deploy.sh --reuse-instance 44255872    # connect a specific existing instance (no rent)
#   scripts/deploy.sh --model-repo https://github.com/DurangoDavid/private-ai-gpu.git \
#                     --model-repo-cmd './install.sh' \
#                     --model-repo-key ~/.ssh/private-ai-gpu_deploy_ed25519
#   scripts/deploy.sh --no-template                # bare CUDA image + onstart install (fallback)
#   scripts/deploy.sh --no-provision               # re-tunnel + retest the terraform-managed instance
#   scripts/deploy.sh --destroy                    # tear down the instance + tunnel unit
#   scripts/deploy.sh --confirm-rent               # skip the confirm-before-spend prompt on a
#                                                  # fresh rent (default: prompts y/N against the
#                                                  # real cheapest offer; non-TTY w/o consent aborts)
set -euo pipefail
cd "$(dirname "$0")/.."

# Auto-load .env (gitignored) when VAST_API_KEY isn't already set, so this script
# works when invoked directly (`scripts/deploy.sh ...`), not just via run.sh
# (which sources .env itself). Only load when VAST_API_KEY is unset so an
# explicitly-exported key (and any other explicit exports) always wins; loading
# pulls in every .env var (VAST_API_KEY, PRIVATE_AI_GPU_REPO, etc.) via set -a.
if [[ -z "${VAST_API_KEY:-}" ]] && [[ -f .env ]]; then
  set -a; . .env 2>/dev/null || true; set +a
fi

ssh_key="${PRIVATE_AI_SSH_KEY:-}"
models_arg=""
no_provision=0
destroy=0
state_dir=".terraform-poc-state"
reuse_instance=""
prefer_existing=0
model_repo=""
model_repo_ref="main"
model_repo_cmd=""
model_repo_key=""
use_template=1
template_image=""
market_type=""
confirm_rent=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --models) models_arg="$2"; shift 2 ;;
    --no-provision) no_provision=1; shift ;;
    --destroy) destroy=1; shift ;;
    --reuse-instance) reuse_instance="$2"; shift 2 ;;
    --prefer-existing) prefer_existing=1; shift ;;
    --model-repo) model_repo="$2"; shift 2 ;;
    --model-repo-ref) model_repo_ref="$2"; shift 2 ;;
    --model-repo-cmd) model_repo_cmd="$2"; shift 2 ;;
    --model-repo-key) model_repo_key="$2"; shift 2 ;;
    --no-template) use_template=0; shift ;;
    --template-image) template_image="$2"; shift 2 ;;
    --market-type) market_type="$2"; shift 2 ;;
    --confirm-rent) confirm_rent=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Env defaults for the GPU gateway repo (so a configured .env makes this a
# one-command flow). PRIVATE_AI_GPU_DEPLOY_KEY is a path to a gitignored deploy
# key — NEVER commit it.
model_repo="${model_repo:-${PRIVATE_AI_GPU_REPO:-}}"
model_repo_cmd="${model_repo_cmd:-${PRIVATE_AI_GPU_REPO_CMD:-}}"
model_repo_key="${model_repo_key:-${PRIVATE_AI_GPU_DEPLOY_KEY:-}}"

export VAST_API_KEY="${VAST_API_KEY:?VAST_API_KEY must be exported (see .env)}"
vast_api_url="${VAST_API_URL:-https://console.vast.ai}"

# --confirm-rent pre-consents the rent so vast_create_instance.sh skips its
# confirm-before-spend prompt. The rent is now invoked DIRECTLY by this script
# (step 2b), NOT inside terraform's local-exec (which has no TTY and so could
# never prompt). deploy.sh inherits the TTY from run.sh, so by default the rent
# gate prompts an explicit y/N against the *real* cheapest offer; --confirm-rent
# (or VAST_CONFIRM_RENT=1) skips that prompt for automation, and a non-TTY run
# without consent still aborts before any spend. VAST_CONFIRM_START likewise
# pre-consents starting a stopped box on the reuse path (also a spend).
if [[ $confirm_rent -eq 1 ]]; then
  export VAST_CONFIRM_RENT=1
  export VAST_CONFIRM_START=1
fi

# ---- destroy path ----
# Terraform no longer manages the Vast instance lifecycle (the apply is
# render-only: enable_provisioning=false -> no null_resource, no rent). So
# `terraform destroy` alone would NOT tear down the live box — it only removes
# the rendered payload files. Destroy the Vast instance explicitly FIRST (it's
# idempotent: a missing/stale instance_id or a 404 is a no-op), then the tunnel
# container, then the terraform-rendered state files.
if [[ $destroy -eq 1 ]]; then
  echo ">>> Tearing down: Vast instance + tunnel container + rendered state"
  node_state_dir=""
  node_name=""
  node_state_dir="$(terraform output -json node_state_dirs 2>/dev/null | jq -r '.[0] // empty')" || true
  node_name="$(terraform output -json node_names 2>/dev/null | jq -r '.[0] // empty')" || true
  if [[ -n "$node_state_dir" && "$node_state_dir" != "null" ]]; then
    scripts/vast_destroy_instance.sh --name "${node_name:-unknown}" --vast-api-url "$vast_api_url" --state-dir "$node_state_dir" || true
  else
    echo "    (no terraform state -> no instance_id to destroy; skip Vast destroy)"
  fi
  docker rm -f private-ai-ollama-tunnel >/dev/null 2>&1 || true
  terraform destroy -auto-approve -var enable_provisioning=false || true
  echo ">>> teardown complete (instance_id was the source of truth; box is gone or was already gone)."
  exit 0
fi

# ---- 0. reuse an existing instance instead of renting ----
# Query the v1 instances list (vast_list_instances_json.sh) for a running instance. If --reuse-instance is given,
# use that id; with --prefer-existing, auto-pick the first running one. On a hit,
# hand off to list-instances.sh (tunnel + test) and stop — no rent, no terraform.
if [[ -n "$reuse_instance" || $prefer_existing -eq 1 ]]; then
  echo ">>> 0/6 checking for an existing Vast.ai instance to reuse..."
  resp="$(scripts/vast_list_instances_json.sh)"
  if [[ -n "$reuse_instance" ]]; then
    target="$reuse_instance"
    if ! printf '%s' "$resp" | jq -e --arg id "$reuse_instance" '.instances[] | select(.id == ($id|tonumber))' >/dev/null 2>&1; then
      echo "Instance ${reuse_instance} is not on this account." >&2
      exit 1
    fi
  else
    target="$(printf '%s' "$resp" | jq -r '[.instances[] | select(.actual_status == "running")] | .[0].id // empty')"
  fi
  if [[ -n "$target" ]]; then
    echo ">>> reusing existing instance ${target} (no provisioning)"
    exec scripts/list-instances.sh --connect "$target" --ssh-key "$ssh_key"
  fi
  [[ -n "$reuse_instance" ]] && { echo "Instance ${reuse_instance} found but not running." >&2; exit 1; }
  echo ">>> no reusable running instance found; proceeding to provision."
fi

# ---- 1. select + size ----
echo ">>> 1/6 select + size models"
sel_args=()
[[ -n "$models_arg" ]] && sel_args=(--models "$models_arg")
sel_out="$(scripts/select-models.sh "${sel_args[@]}")"
echo "$sel_out"
line="$(printf '%s\n' "$sel_out" | grep '^SELECTED:')"
joined="${line#SELECTED:}"; joined="${joined%% *}"        # strip trailing fields
selected_models="$joined"
local_names="$(printf '%s' "$line" | sed -n 's/.*LOCAL://p')"
min_vram="$(printf '%s' "$line" | sed -n 's/.*MIN_VRAM:\([0-9]*\).*/\1/p')"
if [[ -z "$selected_models" ]]; then echo "No models selected." >&2; exit 1; fi

# terraform list literal: ["a","b"]
tf_list="[\"$(printf '%s' "$selected_models" | sed 's/,/","/g')\"]"

# ---- 2. provision (render-only terraform, then rent in THIS process) ----
# The terraform apply is RENDER-ONLY: enable_provisioning=false -> the
# render_only_node materializes search_payload.json / create_payload.json /
# onstart-ollama.sh into .terraform-poc-state/<name>/ but creates NO
# null_resource, so it never rents and never spends. We then rent DIRECTLY here
# (step 2b) by calling vast_create_instance.sh as a child of this script —
# which inherits run.sh's TTY, so the confirm-before-spend gate can finally
# prompt an interactive y/N against the real cheapest offer. (The old design
# ran the rent inside terraform's local-exec provisioner, which has no TTY on
# stdin, so the gate could never prompt and every rent aborted as "no spend".)
if [[ $no_provision -eq 0 ]]; then
  mode_lbl="Ollama template (preinstalled)"
  [[ $use_template -eq 0 ]] && mode_lbl="bare CUDA image + onstart install"
  echo ">>> 2/6 terraform init + render payloads (selected_models=${tf_list}, disk=200, ram=150, mode=${mode_lbl}, NO rent)"
  tf_vars=(
    -var "selected_models=${tf_list}"
    -var "disk_gb=200"
    -var "ram_gb=150"
    -var "enable_provisioning=false"
    -var "use_ollama_template=$([[ $use_template -eq 1 ]] && echo true || echo false)"
    -var "model_repo_url=${model_repo}"
  )
  [[ -n "$template_image" ]] && tf_vars+=(-var "ollama_template_image=${template_image}")
  [[ -n "$market_type" ]] && tf_vars+=(-var "market_type=${market_type}")
  terraform init -input=false
  terraform apply -auto-approve "${tf_vars[@]}"   # render-only: no null_resource, no rent, no spend

  # 2b. rent — in deploy.sh's own TTY so the confirm-before-spend gate prompts.
  node_state_dir="$(terraform output -json node_state_dirs | jq -r '.[0]')"
  node_name="$(terraform output -json node_names | jq -r '.[0]')"
  node_tpl="$(terraform output -json node_template_images | jq -r '.[0] // empty')"
  rent_args=(--name "$node_name" --vast-api-url "$vast_api_url"
             --search-payload "$node_state_dir/search_payload.json"
             --create-payload "$node_state_dir/create_payload.json"
             --state-dir "$node_state_dir")
  # template-image only in template mode (non-empty output); bare-image mode has none.
  [[ -n "$node_tpl" && "$node_tpl" != "null" ]] && rent_args+=(--template-image "$node_tpl")
  echo ">>> 2b/6 rent — confirm-before-spend prompt follows (y/N against the real cheapest offer)"
  scripts/vast_create_instance.sh "${rent_args[@]}"
else
  echo ">>> 2/6 --no-provision: reusing existing instance (skipping render+rent)"
fi

# ---- 3. wait for running + capture connectivity ----
echo ">>> 3/6 wait for instance 'running' + capture IP/SSH port"
node_state_dir="$(terraform output -json node_state_dirs | jq -r '.[0]')"
scripts/vast_instance_info.sh --state-dir "$node_state_dir"
info="$(jq -c '.' "$node_state_dir/instance_info.json")"
ip="$(printf '%s' "$info" | jq -r '.public_ipaddr // empty')"
ssh_port="$(printf '%s' "$info" | jq -r '.ssh_host_port // empty')"
if [[ -z "$ip" || "$ip" == "null" || -z "$ssh_port" || "$ssh_port" == "null" ]]; then
  echo "Could not derive public_ipaddr / ssh_host_port from:" >&2
  jq '.' "$node_state_dir/instance_info.json" >&2
  echo "Inspect the instance's ports map manually (vast_instance_info.sh left it in instance_info.json)." >&2
  exit 1
fi
echo "    instance IP: $ip   SSH host port: $ssh_port"

ssh_base=(ssh -p "$ssh_port" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
[[ -n "$ssh_key" ]] && ssh_base+=(-i "$ssh_key")

# ---- 4. wait for Ollama up ----
echo ">>> 4/6 wait for Ollama on the box (this can take a few min on a fresh boot)"
deadline=$(( $(date +%s) + 900 )) # 15 min for Ollama to answer
have_ollama=0
for _ in $(seq 1 90); do
  if "${ssh_base[@]}" "root@${ip}" "curl -fsS http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
    have_ollama=1; break
  fi
  [[ $(date +%s) -ge $deadline ]] && break
  sleep 10
done
if [[ $have_ollama -ne 1 ]]; then
  echo "Ollama did not come up on the box within 15 min." >&2
  "${ssh_base[@]}" "root@${ip}" "tail -n 50 /workspace/logs/ollama.log" 2>&1 || true
  exit 1
fi

# ---- 4b. deploy external model repo (it downloads the models) ----
if [[ -n "$model_repo" ]]; then
  echo ">>> 4b/6 deploy external model repo onto the box"
  repo_args=(--ip "$ip" --port "$ssh_port" --repo "$model_repo" --ref "$model_repo_ref")
  [[ -n "$ssh_key" ]] && repo_args+=(--ssh-key "$ssh_key")
  [[ -n "$model_repo_cmd" ]] && repo_args+=(--cmd "$model_repo_cmd")
  [[ -n "$model_repo_key" ]] && repo_args+=(--model-repo-key "$model_repo_key")
  scripts/deploy-model-repo.sh "${repo_args[@]}"
fi

# ---- 5. wait for selected LOCAL models to appear in /api/tags ----
echo ">>> 5/6 wait for selected local models in /api/tags (this can take a while)"
IFS=',' read -ra local_arr <<< "$local_names"
missing=("${local_arr[@]}")
deadline=$(( $(date +%s) + 2700 )) # 45 min for pulls
while [[ ${#missing[@]} -gt 0 ]] && [[ $(date +%s) -lt $deadline ]]; do
  tags="$("${ssh_base[@]}" "root@${ip}" "curl -fsS http://127.0.0.1:11434/api/tags" 2>/dev/null || true)"
  new_missing=()
  for m in "${missing[@]}"; do
    if printf '%s' "$tags" | jq -e --arg m "$m" '.models | map(.name) | index($m) != null' >/dev/null 2>&1; then
      echo "    pulled: $m"
    else
      new_missing+=("$m")
    fi
  done
  missing=("${new_missing[@]}")
  [[ ${#missing[@]} -eq 0 ]] && break
  printf '\r    still pulling: %s ' "${missing[*]}"
  sleep 15
done
echo
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Timed out waiting for: ${missing[*]}" >&2
  echo "Check on the box: ssh -p $ssh_port root@$ip 'ollama list' and /workspace/logs/ollama.log" >&2
  exit 1
fi

# ---- 6. tunnel + test ----
echo ">>> 6/6 stand up SSH tunnel -> CPU 0.0.0.0:11434 -> box 127.0.0.1:11434"
scripts/setup-tunnel.sh "$ip" "$ssh_port" "$ssh_key"

sleep 3
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "Tunnel test FAILED: /api/tags not reachable on 127.0.0.1:11434." >&2
  exit 1
fi
echo "    /api/tags reachable. Models on the box:"
curl -s http://127.0.0.1:11434/api/tags | jq -r '.models | map("      - " + .name) | .[]'
first_local="${local_arr[0]:-}"
if [[ -n "$first_local" ]]; then
  echo "    /api/generate smoke test on $first_local:"
  if curl -fsS http://127.0.0.1:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$first_local\",\"prompt\":\"Say OK.\",\"stream\":false}" \
    | jq -r '.response // (.error // "no response")' | head -c 200; then
    echo
    echo
  else
    echo "    /api/generate smoke test FAILED." >&2
    exit 1
  fi
fi
echo
echo "=== private-ai-inference ready ==="
echo "Point the Local LLM Hub CPU VM at:  OLLAMA_BASE_URL=http://127.0.0.1:11434"
echo "                                    (container: http://host.docker.internal:11434)"
echo "Tunnel container:  private-ai-ollama-tunnel  (alpine autossh, docker --restart unless-stopped)"
terraform output -raw has_cloud 2>/dev/null | grep -q true && \
  echo "Cloud models selected: SSH to root@${ip} -p ${ssh_port} and run 'ollama signin' + 'ollama pull <cloud-model>'."
echo "Done."