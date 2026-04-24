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

variable "inference_api_key" {
  type      = string
  sensitive = true
}

variable "model_id" {
  type = string
}

variable "served_model_name" {
  type = string
}

variable "gpu_names" {
  type = list(string)
}

variable "min_gpu_ram_mb" {
  type = number
}

variable "num_gpus" {
  type = number
}

variable "tensor_parallel_size" {
  type = number
}

variable "max_model_len" {
  type = number
}

variable "gpu_memory_utilization" {
  type = number
}

variable "extra_vllm_args" {
  type = list(string)
}
