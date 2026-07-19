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
    # NOTE: no gpu_name whitelist. The gpu_ram floor is the real GPU constraint —
    # any 48GB+ CUDA card fits the selected models, and a whitelist of only A100/
    # H100/H200/RTX-PRO-6000-WS hid the cheap 48GB cards (RTX 6000 Ada, RTX A6000,
    # L40) that can be a fraction of the price. var.gpu_names is kept (advisory,
    # passed through) but NOT filtered on. To restrict to known GPUs, add it back.
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
  # we reach Ollama only over the SSH tunnel (private-ai CPU repo "refuses 0.0.0.0").
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

# NOTE: terraform is RENDER-ONLY. It writes search_payload.json / create_payload.json
# / onstart-ollama.sh into node_state_dir and STOPS — it never rents and never
# spends. Renting happens in scripts/deploy.sh, which calls vast_create_instance.sh
# DIRECTLY (in its own TTY) so the confirm-before-spend gate can prompt y/N. There
# is deliberately NO null_resource / local-exec here: a rent inside terraform's
# provisioner has no TTY on stdin, so the gate could never prompt and every rent
# aborted as "no spend". var.create_instance is retained for backward compat but
# is now a no-op (no provisioner to gate).