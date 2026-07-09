variable "enable_provisioning" {
  description = "When false, Terraform renders payloads but does not rent Vast.ai instances."
  type        = bool
  default     = false
}

variable "selected_models" {
  description = "Fleet models to co-host on one Vast.ai box. Keys of local.model_catalog. VRAM is sized to 1.25x the largest selected LOCAL model; :cloud models are pulled but excluded from sizing."
  type        = list(string)
  default     = ["qwen3_6_35b"]
}

variable "min_vram_floor_gb" {
  description = "Minimum VRAM floor (GB) so a cloud-only selection still rents a real GPU box."
  type        = number
  default     = 16
}

variable "num_gpus" {
  description = "Minimum number of GPUs on the Vast.ai offer. Ollama swaps models, so 1 is the default; raise for very large local models."
  type        = number
  default     = 1
}

variable "default_gpu_names" {
  description = "Broad GPU offer list used when no selected model declares preferred gpu_names."
  type        = list(string)
  default = [
    "A100 SXM4", "A100 PCIe", "A100",
    "H100 SXM", "H100 PCIe", "H100",
    "H200", "H200 NVL",
    "RTX PRO 6000 WS",
  ]
}

variable "ram_gb" {
  description = "Host RAM (GB) to require on the Vast.ai offer. Fixed provision per spec (150)."
  type        = number
  default     = 150
}

variable "disk_gb" {
  description = "Container disk size (GB) on the Vast.ai offer. Fixed provision per spec (200)."
  type        = number
  default     = 200
}

variable "deployment_name" {
  description = "Name prefix for Vast.ai labels and generated files."
  type        = string
  default     = "private-ai-inference"
}

variable "state_dir" {
  description = "Local runtime state directory for generated payloads and Vast.ai create responses."
  type        = string
  default     = ".terraform-poc-state"
}

variable "vast_api_url" {
  description = "Vast.ai API base URL."
  type        = string
  default     = "https://console.vast.ai"
}

variable "market_type" {
  description = "Vast.ai offer market type. The /api/v0/bundles/ search `type` enum is ondemand (fixed on-demand rates, default), bid (interruptible/spot — cheapest, may be preempted), reserved (reserved pricing)."
  type        = string
  default     = "ondemand"

  validation {
    condition     = contains(["ondemand", "bid", "reserved"], var.market_type)
    error_message = "market_type must be one of ondemand, bid, or reserved (the Vast.ai API enum values)."
  }
}

variable "max_dollars_per_hour" {
  description = "Maximum hourly price per Vast.ai offer."
  type        = number
  default     = 20
}

variable "min_reliability" {
  description = "Minimum Vast.ai reliability score."
  type        = number
  default     = 0.99
}

variable "secure_datacenter_only" {
  description = "Require Vast.ai datacenter offers in addition to verified offers."
  type        = bool
  default     = true
}

variable "offer_limit" {
  description = "Maximum offers returned from Vast.ai search."
  type        = number
  default     = 20
}

variable "docker_image" {
  description = "Docker image the Vast.ai instance runs when use_ollama_template=false. A CUDA base so the GPU is usable and the Ollama install script runs; Ollama is installed by the onstart script, not the image."
  type        = string
  default     = "nvidia/cuda:12.4.1-base-ubuntu22.04"
}

variable "use_ollama_template" {
  description = "When true (default), rent from the official Vast.ai Ollama template — Ollama is preinstalled, so onstart skips the install and only serves + pulls. When false, rent a bare CUDA image and install Ollama from scratch in the onstart."
  type        = bool
  default     = true
}

variable "ollama_template_image" {
  description = "Docker image to match in /api/v0/template/ when use_ollama_template=true. The matching template's hash_id is sent to /api/v0/asks/. Default is the official Ollama image."
  type        = string
  default     = "ollama/ollama"
}

variable "model_repo_url" {
  description = "Optional git URL of an external repo that loads models onto the box (deployed after boot by scripts/deploy-model-repo.sh). When set, the onstart defers model pulling to this repo instead of running `ollama pull` itself. Leave empty to pull the selected models directly in the onstart."
  type        = string
  default     = ""
}