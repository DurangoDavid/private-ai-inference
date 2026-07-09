output "node_state_dir" {
  value = "${var.state_dir}/${var.name}"
}

output "name" {
  description = "This node's name (the --name for the rent/destroy scripts; also the Vast instance label)."
  value       = var.name
}

output "template_image" {
  description = "Ollama template image to rent from (empty when use_ollama_template=false)."
  value       = var.use_ollama_template ? var.ollama_template_image : ""
}

output "ollama_models" {
  description = "Ollama model ids this node is configured to pull."
  value       = var.ollama_models
}

output "has_cloud" {
  description = "True when any pulled model is a :cloud model (needs `ollama signin`)."
  value       = var.has_cloud
}