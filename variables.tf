variable "enable_provisioning" {
  description = "When false, Terraform renders payloads but does not rent Vast.ai instances."
  type        = bool
  default     = false
}

variable "selected_model_profile" {
  description = "Model profile key from local.model_profiles."
  type        = string
  default     = "qwen3_coder_30b_fp8"
}

variable "target_concurrency" {
  description = "Target active concurrent developers used for sizing calculations."
  type        = number
  default     = 500

  validation {
    condition     = var.target_concurrency > 0
    error_message = "target_concurrency must be positive."
  }
}

variable "replica_count_override" {
  description = "Set to a number for a bounded POC. Set to null to calculate replicas from target_concurrency."
  type        = number
  default     = 1
  nullable    = true

  validation {
    condition     = var.replica_count_override == null || var.replica_count_override > 0
    error_message = "replica_count_override must be null or positive."
  }
}

variable "deployment_name" {
  description = "Name prefix for Vast.ai labels and generated files."
  type        = string
  default     = "vast-coding-llm"
}

variable "state_dir" {
  description = "Local runtime state directory for generated payloads and Vast.ai create responses."
  type        = string
  default     = ".terraform-poc-state"
}

variable "inference_api_key" {
  description = "API key enforced by vLLM. Use a non-default value before provisioning."
  type        = string
  default     = "change-me"
  sensitive   = true

  validation {
    condition     = length(var.inference_api_key) >= 8
    error_message = "inference_api_key must be at least 8 characters."
  }
}

variable "vast_api_url" {
  description = "Vast.ai API base URL."
  type        = string
  default     = "https://console.vast.ai"
}

variable "market_type" {
  description = "Vast.ai market type."
  type        = string
  default     = "on-demand"

  validation {
    condition     = contains(["on-demand", "reserved", "bid"], var.market_type)
    error_message = "market_type must be one of on-demand, reserved, or bid."
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

variable "disk_gb" {
  description = "Container disk size in GB."
  type        = number
  default     = 250
}

variable "gpu_memory_utilization" {
  description = "vLLM GPU memory utilization."
  type        = number
  default     = 0.90
}

variable "docker_image" {
  description = "Docker image used for inference containers."
  type        = string
  default     = "vllm/vllm-openai:latest"
}

variable "extra_vllm_args" {
  description = "Extra vLLM arguments appended to the generated serve command."
  type        = list(string)
  default     = []
}
