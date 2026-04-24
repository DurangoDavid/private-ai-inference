module "inference_node" {
  source = "./modules/vast_inference_node"
  count  = var.enable_provisioning ? local.replica_count : 0

  name                   = format("%s-%02d", var.deployment_name, count.index + 1)
  state_dir              = var.state_dir
  vast_api_url           = var.vast_api_url
  market_type            = var.market_type
  max_dollars_per_hour   = var.max_dollars_per_hour
  min_reliability        = var.min_reliability
  secure_datacenter_only = var.secure_datacenter_only
  offer_limit            = var.offer_limit
  docker_image           = var.docker_image
  disk_gb                = var.disk_gb
  inference_api_key      = var.inference_api_key
  model_id               = local.selected_profile.model_id
  served_model_name      = local.selected_profile.served_model_name
  gpu_names              = local.selected_profile.gpu_names
  min_gpu_ram_mb         = local.selected_profile.min_gpu_ram_mb
  num_gpus               = local.selected_profile.num_gpus
  tensor_parallel_size   = local.selected_profile.tensor_parallel_size
  max_model_len          = local.selected_profile.max_model_len
  gpu_memory_utilization = var.gpu_memory_utilization
  extra_vllm_args        = local.common_vllm_args
}

module "render_only_node" {
  source = "./modules/vast_inference_node"
  count  = var.enable_provisioning ? 0 : 1

  create_instance        = false
  name                   = format("%s-render-only", var.deployment_name)
  state_dir              = var.state_dir
  vast_api_url           = var.vast_api_url
  market_type            = var.market_type
  max_dollars_per_hour   = var.max_dollars_per_hour
  min_reliability        = var.min_reliability
  secure_datacenter_only = var.secure_datacenter_only
  offer_limit            = var.offer_limit
  docker_image           = var.docker_image
  disk_gb                = var.disk_gb
  inference_api_key      = var.inference_api_key
  model_id               = local.selected_profile.model_id
  served_model_name      = local.selected_profile.served_model_name
  gpu_names              = local.selected_profile.gpu_names
  min_gpu_ram_mb         = local.selected_profile.min_gpu_ram_mb
  num_gpus               = local.selected_profile.num_gpus
  tensor_parallel_size   = local.selected_profile.tensor_parallel_size
  max_model_len          = local.selected_profile.max_model_len
  gpu_memory_utilization = var.gpu_memory_utilization
  extra_vllm_args        = local.common_vllm_args
}
