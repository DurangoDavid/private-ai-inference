module "inference_node" {
  source = "./modules/vast_inference_node"
  count  = var.enable_provisioning ? 1 : 0

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
  ram_gb                 = var.ram_gb
  ollama_models          = local.ollama_models
  has_cloud              = local.has_cloud
  gpu_names              = local.gpu_names
  min_gpu_ram_mb         = local.min_gpu_ram_mb
  num_gpus               = var.num_gpus
  use_ollama_template    = var.use_ollama_template
  ollama_template_image  = var.ollama_template_image
  model_repo_url         = var.model_repo_url
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
  ram_gb                 = var.ram_gb
  ollama_models          = local.ollama_models
  has_cloud              = local.has_cloud
  gpu_names              = local.gpu_names
  min_gpu_ram_mb         = local.min_gpu_ram_mb
  num_gpus               = var.num_gpus
  use_ollama_template    = var.use_ollama_template
  ollama_template_image  = var.ollama_template_image
  model_repo_url         = var.model_repo_url
}