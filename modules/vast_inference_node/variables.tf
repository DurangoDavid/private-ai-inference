variable "create_instance" {
  description = "When false, render payloads without creating Vast.ai instances."
  type        = bool
  default     = true
}

variable "name" {
  type = string
}

variable "state_dir" {
  type = string
}

variable "vast_api_url" {
  type = string
}

variable "market_type" {
  type = string
}

variable "max_dollars_per_hour" {
  type = number
}

variable "min_reliability" {
  type = number
}

variable "secure_datacenter_only" {
  type = bool
}

variable "offer_limit" {
  type = number
}

variable "docker_image" {
  type = string
}

variable "disk_gb" {
  type = number
}

variable "ram_gb" {
  description = "Host RAM (GB) to require on the Vast.ai offer (search filter cpu_ram)."
  type        = number
}

variable "ollama_models" {
  description = "Ollama model ids to pull on the box (local now, :cloud after `ollama signin`)."
  type        = list(string)
}

variable "has_cloud" {
  description = "True when any selected model is a :cloud model (drives the onstart signin note)."
  type        = bool
}

variable "use_ollama_template" {
  description = "When true, rent from the official Ollama template (Ollama preinstalled) via /api/v0/template/ + /api/v0/asks/. When false, use a bare CUDA image and install Ollama in the onstart."
  type        = bool
  default     = true
}

variable "ollama_template_image" {
  description = "Docker image to match in /api/v0/template/ when use_ollama_template is true (e.g. ollama/ollama). The matching template's hash_id is sent to /api/v0/asks/."
  type        = string
  default     = "ollama/ollama"
}

variable "model_repo_url" {
  description = "Optional git URL of an external repo that loads models onto the box (deployed after boot by scripts/deploy-model-repo.sh). When set, the onstart defers model pulling to this repo instead of running `ollama pull` itself."
  type        = string
  default     = ""
}

variable "gpu_names" {
  description = "Advisory only — NOT used as a search filter. The gpu_ram floor is the real GPU constraint (any 48GB+ CUDA card fits the models), so the cheapest card wins. A whitelist of only A100/H100/H200/RTX-PRO-6000-WS hid cheap 48GB cards (RTX 6000 Ada, RTX A6000, L40). To restrict to known GPUs, re-add a gpu_name filter in main.tf."
  type        = list(string)
}

variable "min_gpu_ram_mb" {
  type = number
}

variable "num_gpus" {
  type = number
}