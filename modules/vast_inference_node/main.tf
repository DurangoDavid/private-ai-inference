locals {
  node_state_dir = "${var.state_dir}/${var.name}"

  search_payload = merge({
    limit             = var.offer_limit
    type              = var.market_type
    verified          = { eq = true }
    rentable          = { eq = true }
    rented            = { eq = false }
    direct_port_count = { gte = 1 }
    reliability       = { gte = var.min_reliability }
    dph_total         = { lte = var.max_dollars_per_hour }
    disk_space        = { gte = var.disk_gb }
    num_gpus          = { gte = var.num_gpus }
    gpu_ram           = { gte = var.min_gpu_ram_mb }
    gpu_name          = { in = var.gpu_names }
    }, var.secure_datacenter_only ? {
    datacenter = { eq = true }
  } : {})

  vllm_onstart = templatefile("${path.root}/templates/onstart-vllm.sh.tftpl", {
    model_id               = var.model_id
    served_model_name      = var.served_model_name
    inference_api_key      = var.inference_api_key
    tensor_parallel_size   = var.tensor_parallel_size
    max_model_len          = var.max_model_len
    gpu_memory_utilization = var.gpu_memory_utilization
    extra_vllm_args        = join(" ", var.extra_vllm_args)
  })

  create_payload = {
    image   = var.docker_image
    label   = var.name
    disk    = var.disk_gb
    runtype = "ssh_direct"
    env = {
      "-p 8000:8000" = "1"
    }
    onstart = local.vllm_onstart
  }
}

resource "local_sensitive_file" "search_payload" {
  filename        = "${local.node_state_dir}/search_payload.json"
  content         = jsonencode(local.search_payload)
  file_permission = "0600"
}

resource "local_sensitive_file" "create_payload" {
  filename        = "${local.node_state_dir}/create_payload.json"
  content         = jsonencode(local.create_payload)
  file_permission = "0600"
}

resource "local_sensitive_file" "onstart" {
  filename        = "${local.node_state_dir}/onstart-vllm.sh"
  content         = local.vllm_onstart
  file_permission = "0700"
}

resource "null_resource" "instance" {
  count = var.create_instance ? 1 : 0

  triggers = {
    name                = var.name
    node_state_dir      = local.node_state_dir
    vast_api_url        = var.vast_api_url
    search_payload_sha  = sha256(jsonencode(local.search_payload))
    create_payload_sha  = sha256(jsonencode(local.create_payload))
    create_payload_path = local_sensitive_file.create_payload.filename
    search_payload_path = local_sensitive_file.search_payload.filename
  }

  provisioner "local-exec" {
    command = "${path.root}/scripts/vast_create_instance.sh --name '${self.triggers.name}' --vast-api-url '${self.triggers.vast_api_url}' --search-payload '${self.triggers.search_payload_path}' --create-payload '${self.triggers.create_payload_path}' --state-dir '${self.triggers.node_state_dir}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.root}/scripts/vast_destroy_instance.sh --name '${self.triggers.name}' --vast-api-url '${self.triggers.vast_api_url}' --state-dir '${self.triggers.node_state_dir}'"
  }

  depends_on = [
    local_sensitive_file.create_payload,
    local_sensitive_file.search_payload,
    local_sensitive_file.onstart
  ]
}
