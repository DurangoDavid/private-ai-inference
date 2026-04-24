output "node_state_dir" {
  value = "${var.state_dir}/${var.name}"
}

output "served_model_name" {
  value = var.served_model_name
}

output "model_id" {
  value = var.model_id
}
