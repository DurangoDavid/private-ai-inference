locals {
  # ---------------------------------------------------------------------------
  # Fleet catalog — the Local LLM Hub (README1.md) GPU fleet, encoded as data.
  # This catalog is the alignment seam between this provisioner and the CPU VM
  # app's fleet: a model is added/removed here + pulled on the box, no app-side
  # code change (README1.md's "nothing static" rule for the GPU box).
  #
  # Every entry has the SAME attribute shape (Terraform map values must share a
  # type) — use [] / false as the empty value, never omit an attribute.
  #
  # ollama_name : the `ollama pull` argument (Ollama model id, not a HF id).
  # cloud       : true => served from Ollama cloud via `ollama signin`, ~0 local
  #              VRAM => EXCLUDED from VRAM sizing (weight_gb ignored when cloud).
  # weight_gb   : best-effort GB footprint of the Ollama default-pull for the
  #              LARGEST selected local model drives min VRAM (×1.25). Several
  #              fleet names are forward-looking/aspirational (per README1.md);
  #              treat these as tuning constants — verify on a real box with
  #              `ollama show` and adjust here.
  # role        : README1.md routing_role tag (documentation / future filtering).
  # vision      : README1.md vision flag (documentation / future filtering).
  # gpu_names   : preferred Vast.ai GPU offers for this model; empty => use the
  #              var.default_gpu_names broad list.
  # ---------------------------------------------------------------------------
  model_catalog = {
    qwen3_6_35b = {
      ollama_name = "qwen3.6:35b"
      cloud       = false
      weight_gb   = 22
      role        = "local_execution"
      vision      = false
      gpu_names   = ["A100 SXM4", "A100 PCIe", "A100", "H100 SXM", "H100 PCIe", "H100", "H200", "H200 NVL", "RTX PRO 6000 WS"]
    }
    qwen3_coder_next = {
      ollama_name = "qwen3-coder-next"
      cloud       = false
      weight_gb   = 22
      role        = "local_coding"
      vision      = false
      gpu_names   = ["A100 SXM4", "A100 PCIe", "A100", "H100 SXM", "H100 PCIe", "H100", "H200", "H200 NVL", "RTX PRO 6000 WS"]
    }
    gemma3_27b = {
      ollama_name = "gemma3:27b"
      cloud       = false
      weight_gb   = 17
      role        = "local_vision"
      vision      = true
      gpu_names   = []
    }
    glm_5_2_cloud = {
      ollama_name = "glm-5.2:cloud"
      cloud       = true
      weight_gb   = 0
      role        = "control_plane"
      vision      = false
      gpu_names   = []
    }
    mistral_large_3_675b = {
      ollama_name = "mistral-large-3:675b-cloud"
      cloud       = true
      weight_gb   = 0
      role        = "cloud_synthesis"
      vision      = true
      gpu_names   = []
    }
    deepseek_v4_pro_cloud = {
      ollama_name = "deepseek-v4-pro:cloud"
      cloud       = true
      weight_gb   = 0
      role        = "cloud_reasoning"
      vision      = false
      gpu_names   = []
    }
    qwen2_5_0_5b = {
      ollama_name = "qwen2.5:0.5b"
      cloud       = false
      weight_gb   = 1
      role        = "infra_router"
      vision      = false
      gpu_names   = []
    }
    nomic_embed = {
      ollama_name = "nomic-embed-text"
      cloud       = false
      weight_gb   = 1
      role        = "embedding"
      vision      = false
      gpu_names   = []
    }
    x_z_image_turbo = {
      ollama_name = "x/z-image-turbo:latest"
      cloud       = false
      weight_gb   = 4
      role        = "image_generation"
      vision      = false
      gpu_names   = []
    }
  }

  # ----- selection + sizing (README1.md spec) -----
  # min VRAM = clamp(1.25 × the weight GB of the LARGEST selected LOCAL model,
  #                  floor=var.min_vram_floor_gb, ceiling=var.max_vram_ceiling_gb).
  # :cloud models are excluded (served from Ollama cloud, ~0 local VRAM).
  # SSD is fixed at var.disk_gb (200), RAM at var.ram_gb (40).
  selected_set      = toset(var.selected_models)
  selected_entries  = { for k, v in local.model_catalog : k => v if contains(local.selected_set, k) }
  local_selected    = { for k, v in local.selected_entries : k => v if !v.cloud }
  local_weight_list = [for v in local.local_selected : v.weight_gb]
  largest_local_gb  = length(local.local_weight_list) > 0 ? max(local.local_weight_list...) : 0
  raw_min_vram_gb   = 1.25 * local.largest_local_gb
  floored_min_vram_gb = max(ceil(local.raw_min_vram_gb), var.min_vram_floor_gb)
  min_vram_gb       = min(local.floored_min_vram_gb, var.max_vram_ceiling_gb)
  min_gpu_ram_mb    = local.min_vram_gb * 1024
  num_gpus          = var.num_gpus # Ollama swaps models; no tensor-parallel sizing needed

  # models to pull on the box (local now, :cloud after `ollama signin`)
  ollama_models = [for v in local.selected_entries : v.ollama_name]
  has_cloud     = anytrue([for v in local.selected_entries : v.cloud])

  # GPU offer names: union of per-model preferences, else the broad default list
  selected_gpu_names = distinct(flatten([for v in local.selected_entries : v.gpu_names]))
  gpu_names          = length(local.selected_gpu_names) > 0 ? local.selected_gpu_names : var.default_gpu_names
}