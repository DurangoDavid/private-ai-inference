output "node_state_dir" {
  value = "${var.state_dir}/${var.name}"
}

output "ollama_models" {
  description = "Ollama model ids this node is configured to pull."
  value       = var.ollama_models
}

output "has_cloud" {
  description = "True when any pulled model is a :cloud model (needs `ollama signin`)."
  value       = var.has_cloud
}