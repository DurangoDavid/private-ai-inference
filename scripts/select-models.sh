#!/usr/bin/env bash
# Ask the user which fleet models to co-host on one Vast.ai box, compute the
# 1.25x-largest-local-model VRAM (SSD 200, RAM 150 fixed), and emit the
# selection for deploy.sh / terraform apply.
#
#   select-models.sh                       # interactive numbered menu
#   select-models.sh --models a,b,c        # non-interactive
#   select-models.sh --models all           # every catalog entry
#
# Catalog is embedded here for a dependency-free picker. KEEP IN SYNC with
# local.model_catalog in locals.tf (slug, cloud flag, weight_gb).
set -euo pipefail

# slug | ollama_name | cloud(0/1) | weight_gb | role
CATALOG=(
  # local
  "qwen3_6_35b|qwen3.6:35b|0|22|local_execution"
  "qwen3_coder_next|qwen3-coder-next|0|22|local_coding"
  "gemma3_27b|gemma3:27b|0|17|local_vision"
  "nomic_embed|nomic-embed-text|0|1|embedding"
  "qwen2_5_0_5b|qwen2.5:0.5b|0|1|infra_router"
  # cloud
  "glm_5_2_cloud|glm-5.2:cloud|1|0|control_plane"
  "deepseek_v4_pro_cloud|deepseek-v4-pro:cloud|1|0|cloud_reasoning"
  "mistral_large_3_675b|mistral-large-3:675b-cloud|1|0|cloud_vision"
  # image
  "x_z_image_turbo|x/z-image-turbo:latest|0|4|image_generation"
)
MIN_VRAM_FLOOR=48
MIN_VRAM_CEILING=250

slug_of()      { printf '%s' "${1%%|*}"; }
rest_of()      { s="${1#|}"; printf '%s' "${s}"; }   # not used directly
field()        { printf '%s' "$(printf '%s' "$1" | cut -d'|' -f"$2")"; }

valid_slug() {
  local want="$1"
  for entry in "${CATALOG[@]}"; do
    [[ "$(field "$entry" 1)" == "$want" ]] && return 0
  done
  return 1
}

cloud_of() {
  for entry in "${CATALOG[@]}"; do
    if [[ "$(field "$entry" 1)" == "$1" ]]; then
      printf '%s' "$(field "$entry" 3)"
      return
    fi
  done
}
weight_of() {
  for entry in "${CATALOG[@]}"; do
    if [[ "$(field "$entry" 1)" == "$1" ]]; then
      printf '%s' "$(field "$entry" 4)"
      return
    fi
  done
}
ollama_of() {
  for entry in "${CATALOG[@]}"; do
    if [[ "$(field "$entry" 1)" == "$1" ]]; then
      printf '%s' "$(field "$entry" 2)"
      return
    fi
  done
}
role_of() {
  for entry in "${CATALOG[@]}"; do
    if [[ "$(field "$entry" 1)" == "$1" ]]; then
      printf '%s' "$(field "$entry" 5)"
      return
    fi
  done
}

selected=()
if [[ "${1:-}" == "--models" ]]; then
  arg="${2:-}"
  if [[ -z "$arg" ]]; then echo "--models requires an argument" >&2; exit 2; fi
  if [[ "$arg" == "all" ]]; then
    for entry in "${CATALOG[@]}"; do selected+=("$(field "$entry" 1)"); done
  else
    IFS=',' read -ra parts <<< "$arg"
    for p in "${parts[@]}"; do
      p="${p// /}"
      if ! valid_slug "$p"; then
        echo "Unknown model key: $p" >&2
        echo "Valid: $(for e in "${CATALOG[@]}"; do field "$e" 1; echo; done | paste -sd' ' -)" >&2
        exit 2
      fi
      selected+=("$p")
    done
  fi
else
  # Interactive UI goes to STDERR so a caller capturing stdout (run.sh:
  # `sel_out="$(scripts/select-models.sh)"`) still sees the menu live and only
  # captures the machine-readable SELECTED: line at the end. Printing the menu
  # to stdout would swallow it into the variable -> "nothing happens" + a hang.
  echo "private-ai-inference — select fleet models to co-host on one Vast.ai box" >&2
  echo "VRAM is sized to 1.25x the largest selected LOCAL model; :cloud models" >&2
  echo "are pulled but excluded from VRAM sizing (served from Ollama cloud)." >&2
  echo "SSD=200GB, RAM=40GB are fixed." >&2
  echo >&2
  i=1
  for entry in "${CATALOG[@]}"; do
    slug="$(field "$entry" 1)"; name="$(field "$entry" 2)"; cloud="$(field "$entry" 3)"
    weight="$(field "$entry" 4)"; role="$(field "$entry" 5)"
    tag="local"; [[ "$cloud" == "1" ]] && tag=":cloud"; [[ "$role" == image_* ]] && tag="image"
    printf '%2d) %-22s %-32s %2sGB  %-16s [%s]\n' "$i" "$slug" "$name" "$weight" "$role" "$tag" >&2
    i=$((i+1))
  done
  echo >&2
  echo "Enter the numbers to co-host, comma-separated (e.g. 1,3,8), or 'all':" >&2
  read -r ans
  if [[ -z "$ans" ]]; then echo "No selection." >&2; exit 1; fi
  if [[ "$ans" == "all" ]]; then
    for entry in "${CATALOG[@]}"; do selected+=("$(field "$entry" 1)"); done
  else
    IFS=',' read -ra picks <<< "$ans"
    for n in "${picks[@]}"; do
      n="${n// /}"
      if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#CATALOG[@]} )); then
        echo "Invalid pick: $n" >&2; exit 2
      fi
      entry="${CATALOG[$((n-1))]}"
      selected+=("$(field "$entry" 1)")
    done
  fi
fi

# Dedupe + compute sizing.
declare -A seen
uniq=()
for s in "${selected[@]}"; do
  if [[ -z "${seen[$s]:-}" ]]; then seen[$s]=1; uniq+=("$s"); fi
done

largest_local=0
local_models=()
cloud_models=()
for s in "${uniq[@]}"; do
  if [[ "$(cloud_of "$s")" == "1" ]]; then
    cloud_models+=("$s")
  else
    local_models+=("$s")
    w="$(weight_of "$s")"
    (( w > largest_local )) && largest_local=$w
  fi
done

min_vram=$(awk -v w="$largest_local" -v f="$MIN_VRAM_FLOOR" -v c="$MIN_VRAM_CEILING" 'BEGIN{ v=int((w*1.25)+0.999999); if (v<f) v=f; if (v>c) v=c; printf "%d", v }')

# Human-readable summary -> stderr (see note above); only the SELECTED: line
# below goes to stdout for the caller to capture.
echo >&2
echo "Selected:" >&2
for s in "${uniq[@]}"; do
  flag="local"; [[ "$(cloud_of "$s")" == "1" ]] && flag=":cloud"
  [[ "$(role_of "$s")" == image_* ]] && flag="image"
  printf '  - %-22s %s  (%s)\n' "$s" "$(ollama_of "$s")" "$flag" >&2
done
echo >&2
echo "Largest local model weight: ${largest_local}GB" >&2
echo "Min VRAM (1.25x largest local, floored at ${MIN_VRAM_FLOOR}GB, capped at ${MIN_VRAM_CEILING}GB): ${min_vram}GB" >&2
echo "SSD: 200GB (fixed)   RAM: 40GB (fixed)" >&2
if [[ ${#cloud_models[@]} -gt 0 ]]; then
  echo "Cloud models present: after the box boots, SSH in once and run 'ollama signin'," >&2
  echo "  then 'ollama pull <cloud-model>' for each." >&2
fi

# Machine-readable line for deploy.sh (LOCAL = local-model ollama names to wait
# for on the box; cloud models are excluded — they need `ollama signin` first).
joined=""
for s in "${uniq[@]}"; do joined="${joined:+$joined,}$s"; done
local_names=""
for s in "${local_models[@]:-}"; do
  [[ -n "$s" ]] && local_names="${local_names:+$local_names,}$(ollama_of "$s")"
done
printf '\nSELECTED:%s MIN_VRAM:%s LOCAL:%s\n' "$joined" "$min_vram" "$local_names"