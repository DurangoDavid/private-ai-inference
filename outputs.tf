output "selected_models" {
  description = "Fleet model keys selected for co-hosting."
  value       = var.selected_models
}

output "ollama_models" {
  description = "Ollama model ids that will be pulled on the box (local now, :cloud after `ollama signin`)."
  value       = local.ollama_models
}

output "has_cloud" {
  description = "True when any selected model is a :cloud model (needs a one-time `ollama signin` on the box)."
  value       = local.has_cloud
}

output "min_vram_gb" {
  description = "Computed minimum VRAM (GB) = 1.25 x largest selected LOCAL model's weight_gb, floored at min_vram_floor_gb."
  value       = local.min_vram_gb
}

output "ram_gb" {
  description = "Host RAM provisioned (GB)."
  value       = var.ram_gb
}

output "disk_gb" {
  description = "Container disk provisioned (GB)."
  value       = var.disk_gb
}

output "provisioning_enabled" {
  description = "Whether this apply rents Vast.ai instances."
  value       = var.enable_provisioning
}

output "node_state_dirs" {
  description = "Local generated state directories (instance_id lives in <dir>/instance_id)."
  value = var.enable_provisioning ? [
    for node in module.inference_node : node.node_state_dir
    ] : [
    for node in module.render_only_node : node.node_state_dir
  ]
}

output "node_names" {
  description = "Node names — the --name for the rent/destroy scripts and the Vast instance label. (render-only name when enable_provisioning=false; deploy.sh reads this to rent outside terraform.)"
  value = var.enable_provisioning ? [
    for node in module.inference_node : node.name
    ] : [
    for node in module.render_only_node : node.name
  ]
}

output "node_template_images" {
  description = "Ollama template image per node (empty when use_ollama_template=false). deploy.sh passes this to vast_create_instance.sh."
  value = var.enable_provisioning ? [
    for node in module.inference_node : node.template_image
    ] : [
    for node in module.render_only_node : node.template_image
  ]
}

output "tunnel_command" {
  description = "Guidance: after `apply`, derive ip + ssh port from the instance, then run this to stand up the CPU-side tunnel. (IP/SSH port come from the Vast.ai API via scripts/vast_instance_info.sh, not a Terraform output, to avoid the provisioner/data-source race on first apply.)"
  value = var.enable_provisioning && length(module.inference_node) > 0 ? format("%s\n%s",
    "scripts/vast_instance_info.sh --state-dir '${module.inference_node[0].node_state_dir}'  # prints {public_ipaddr, ssh_host_port}",
    "scripts/setup-tunnel.sh <public_ipaddr> <ssh_host_port> <ssh-key-path>"
  ) : "enable_provisioning=false; no instance to tunnel to."
}