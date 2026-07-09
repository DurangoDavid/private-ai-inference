locals {
  node_state_dir = "${var.state_dir}/${var.name}"

  # Vast.ai search/bundle filter. Ollama runs loopback-only on the box and is
  # reached over the SSH tunnel from the CPU VM, so we do NOT publish 11434.
  # direct_port_count >= 1 guarantees an SSH direct port for the tunnel.
  search_payload = merge({
    limit             = var.offer_limit
    type              = var.market_type
    verified          = { eq = true }
    rentable          = { eq = true }
    rented            = { eq = false }
    direct_port_count = { gte = 1 }
    reliability       = { gte = var.min_reliability }
    dph_total         = { lte = var.max_dollars_per_hour }
    disk_space        = { gte = var.disk_gb }            # GB
    cpu_ram           = { gte = var.ram_gb * 1024 }      # MB (Vast filters: disk_space=GB, cpu_ram/gpu_ram=MB)
    num_gpus          = { gte = var.num_gpus }
    gpu_ram           = { gte = var.min_gpu_ram_mb }
    gpu_name          = { in = var.gpu_names }
    }, var.secure_datacenter_only ? {
    datacenter = { eq = true }
  } : {})

  ollama_onstart = templatefile("${path.root}/templates/onstart-ollama.sh.tftpl", {
    ollama_models  = var.ollama_models
    has_cloud      = var.has_cloud
    skip_install   = var.use_ollama_template
    model_repo_url = var.model_repo_url
  })

  # create_payload has one consistent shape. In template mode `image` is the
  # template image (overriding the template's image with the identical value is a
  # no-op) and vast_create_instance.sh merges in `template_hash_id`; in bare mode
  # `image` is the CUDA base and the onstart installs Ollama. `env` always pins
  # OLLAMA_HOST to loopback — the template's default 0.0.0.0:21434 would publish
  # Ollama; our value wins the env merge so the published port is a dead map and
  # we reach Ollama only over the SSH tunnel (README1.md "refuses 0.0.0.0").
  create_payload = {
    image   = var.use_ollama_template ? var.ollama_template_image : var.docker_image
    label   = var.name
    disk    = var.disk_gb
    runtype = "ssh_direct"
    env     = { OLLAMA_HOST = "127.0.0.1:11434" }
    onstart = local.ollama_onstart
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
  filename        = "${local.node_state_dir}/onstart-ollama.sh"
  content         = local.ollama_onstart
  file_permission = "0700"
}

resource "null_resource" "instance" {
  count = var.create_instance ? 1 : 0

  triggers = {
    name                 = var.name
    node_state_dir       = local.node_state_dir
    vast_api_url         = var.vast_api_url
    search_payload_sha   = sha256(jsonencode(local.search_payload))
    create_payload_sha   = sha256(jsonencode(local.create_payload))
    create_payload_path  = local_sensitive_file.create_payload.filename
    search_payload_path  = local_sensitive_file.search_payload.filename
    use_ollama_template  = var.use_ollama_template
    ollama_template_image = var.ollama_template_image
    model_repo_url       = var.model_repo_url
  }

  provisioner "local-exec" {
    command = join(" ", [
      "${path.root}/scripts/vast_create_instance.sh",
      "--name '${self.triggers.name}'",
      "--vast-api-url '${self.triggers.vast_api_url}'",
      "--search-payload '${self.triggers.search_payload_path}'",
      "--create-payload '${self.triggers.create_payload_path}'",
      "--state-dir '${self.triggers.node_state_dir}'",
      var.use_ollama_template ? "--template-image '${var.ollama_template_image}'" : "",
    ])
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