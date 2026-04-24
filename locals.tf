locals {
  model_profiles = {
    qwen3_coder_30b_fp8 = {
      model_id                          = "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
      served_model_name                 = "qwen3-coder-30b-a3b-instruct"
      gpu_names                         = ["A100 SXM4", "A100 PCIe", "A100", "H100 SXM", "H100 PCIe", "H100", "H200", "H200 NVL", "RTX PRO 6000 WS"]
      min_gpu_ram_mb                    = 40000
      num_gpus                          = 1
      tensor_parallel_size              = 1
      max_model_len                     = 32768
      estimated_concurrency_per_replica = 10
      default_extra_args                = ["--enable-prefix-caching", "--enable-auto-tool-choice", "--tool-call-parser", "qwen3_coder"]
      quality_position                  = "practical-first-poc"
    }

    glm_5_fp8 = {
      model_id                          = "zai-org/GLM-5-FP8"
      served_model_name                 = "glm-5-fp8"
      gpu_names                         = ["H100 SXM", "H100 PCIe", "H100", "H200", "H200 NVL", "B200"]
      min_gpu_ram_mb                    = 80000
      num_gpus                          = 8
      tensor_parallel_size              = 8
      max_model_len                     = 131072
      estimated_concurrency_per_replica = 25
      default_extra_args                = ["--enable-auto-tool-choice", "--tool-call-parser", "glm47", "--reasoning-parser", "glm45"]
      quality_position                  = "best-open-candidate"
    }

    glm_4_7_fp8 = {
      model_id                          = "zai-org/GLM-4.7-FP8"
      served_model_name                 = "glm-4.7-fp8"
      gpu_names                         = ["H200", "H200 NVL", "B200"]
      min_gpu_ram_mb                    = 120000
      num_gpus                          = 4
      tensor_parallel_size              = 4
      max_model_len                     = 131072
      estimated_concurrency_per_replica = 18
      default_extra_args                = ["--enable-auto-tool-choice", "--tool-call-parser", "glm47", "--reasoning-parser", "glm45"]
      quality_position                  = "strong-open-candidate"
    }

    deepseek_v3_2_exp = {
      model_id                          = "deepseek-ai/DeepSeek-V3.2-Exp"
      served_model_name                 = "deepseek-v3.2-exp"
      gpu_names                         = ["H100 SXM", "H100 PCIe", "H100", "H200", "H200 NVL", "B200"]
      min_gpu_ram_mb                    = 80000
      num_gpus                          = 8
      tensor_parallel_size              = 8
      max_model_len                     = 131072
      estimated_concurrency_per_replica = 20
      default_extra_args                = ["--enable-prefix-caching"]
      quality_position                  = "long-context-contender"
    }

    kimi_k2_thinking = {
      model_id                          = "moonshotai/Kimi-K2-Thinking"
      served_model_name                 = "kimi-k2-thinking"
      gpu_names                         = ["H100 SXM", "H100 PCIe", "H100", "H200", "H200 NVL", "B200"]
      min_gpu_ram_mb                    = 80000
      num_gpus                          = 8
      tensor_parallel_size              = 8
      max_model_len                     = 131072
      estimated_concurrency_per_replica = 20
      default_extra_args                = ["--enable-prefix-caching"]
      quality_position                  = "agentic-reasoning-contender"
    }
  }

  selected_profile = local.model_profiles[var.selected_model_profile]

  calculated_replica_count = ceil(var.target_concurrency / local.selected_profile.estimated_concurrency_per_replica)
  replica_count            = var.replica_count_override == null ? local.calculated_replica_count : var.replica_count_override

  common_vllm_args = concat(local.selected_profile.default_extra_args, var.extra_vllm_args)
}
