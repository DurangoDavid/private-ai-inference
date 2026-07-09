# One render-only inference node. Terraform renders the Vast.ai search/create
# payloads + onstart into var.state_dir/<name>/ and STOPS — it never rents
# (no null_resource, no local-exec). Renting is scripts/deploy.sh's job, in its
# own TTY, so the confirm-before-spend gate can prompt. enable_provisioning is
# retained as an informational var (see output "provisioning_enabled") but no
# longer toggles a rent — terraform is always render-only now.
module "inference_node" {
  source = "./modules/vast_inference_node"
  count  = 1

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