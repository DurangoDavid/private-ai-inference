output "selected_model_profile" {
  description = "Selected model profile and sizing metadata."
  value = {
    key                               = var.selected_model_profile
    model_id                          = local.selected_profile.model_id
    served_model_name                 = local.selected_profile.served_model_name
    quality_position                  = local.selected_profile.quality_position
    target_concurrency                = var.target_concurrency
    calculated_replica_count          = local.calculated_replica_count
    effective_replica_count           = local.replica_count
    estimated_concurrency_per_replica = local.selected_profile.estimated_concurrency_per_replica
  }
}

output "provisioning_enabled" {
  description = "Whether this apply rents Vast.ai instances."
  value       = var.enable_provisioning
}

output "node_state_dirs" {
  description = "Local generated state directories."
  value = var.enable_provisioning ? [
    for node in module.inference_node : node.node_state_dir
    ] : [
    for node in module.render_only_node : node.node_state_dir
  ]
}

output "smoke_test_model" {
  description = "Model name to use with smoke_test.py and load_test.py."
  value       = local.selected_profile.served_model_name
}
