#!/usr/bin/env bash
set -euo pipefail

name=""
vast_api_url="https://console.vast.ai"
search_payload=""
create_payload=""
state_dir=""
template_image=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    --vast-api-url)
      vast_api_url="$2"
      shift 2
      ;;
    --search-payload)
      search_payload="$2"
      shift 2
      ;;
    --create-payload)
      create_payload="$2"
      shift 2
      ;;
    --state-dir)
      state_dir="$2"
      shift 2
      ;;
    --template-image)
      # When set, rent from a Vast.ai template (Ollama preinstalled) instead of
      # the bare image in create_payload: search /api/v0/template/ for this image,
      # take the matching template's hash_id, merge it into create_payload, then
      # PUT /api/v0/asks/<offer>/ with the merged body.
      template_image="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${VAST_API_KEY:-}" ]]; then
  echo "VAST_API_KEY must be exported before terraform apply." >&2
  exit 1
fi

if [[ -z "$name" || -z "$search_payload" || -z "$create_payload" || -z "$state_dir" ]]; then
  echo "Missing required arguments." >&2
  exit 2
fi

mkdir -p "$state_dir"

# Template mode: look up the Ollama template's hash_id by Docker image, then
# merge template_hash_id into the create payload before renting. The payload
# already carries our env/onstart overrides (OLLAMA_HOST=127.0.0.1:11434, the
# serve+pull onstart); the template supplies the preinstalled Ollama image.
if [[ -n "$template_image" ]]; then
  echo "Searching Vast.ai templates for image: ${template_image}" >&2
  templates_response="$state_dir/templates.json"
  curl -fsS -G \
    --url "${vast_api_url%/}/api/v0/template/" \
    --header "Authorization: Bearer ${VAST_API_KEY}" \
    --data-urlencode "select_filters={\"image\":{\"eq\":\"${template_image}\"}}" \
    --data-urlencode "select_cols=[\"*\"]" \
    > "$templates_response"

  # Prefer recommended templates, then the most-created (a popularity proxy).
  # The composite array key sorts lexicographically: [recommended-not, -count]
  # — recommended (not=false) first, then highest count_created. Sub-expressions
  # are fully parenthesized so the `|` pipe doesn't swallow the comma.
  template_hash_id="$(jq -r '
    .templates
    | sort_by([ ((.recommended // false) | not), -(.count_created // 0) ])
    | .[0].hash_id // empty' "$templates_response")"

  if [[ -z "$template_hash_id" || "$template_hash_id" == "null" ]]; then
    echo "No Vast.ai template found for image ${template_image}." >&2
    echo "Templates returned:" >&2
    jq '.templates | map({name, image, hash_id, recommended, count_created})' "$templates_response" >&2
    exit 1
  fi
  echo "Using Ollama template hash_id: ${template_hash_id}" >&2

  merged_payload="$state_dir/create_payload_merged.json"
  jq --arg h "$template_hash_id" '. + {template_hash_id: $h}' "$create_payload" > "$merged_payload"
  create_payload="$merged_payload"
fi

offers_response="$state_dir/offers.json"
offer="$state_dir/offer.json"
offer_id_file="$state_dir/offer_id"
create_response="$state_dir/create_response.json"
instance_id_file="$state_dir/instance_id"

curl -fsS \
  --request POST \
  --url "${vast_api_url%/}/api/v0/bundles/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  --header "Content-Type: application/json" \
  --data @"$search_payload" \
  > "$offers_response"

jq '[.offers[]] | sort_by(.dph_total) | .[0]' "$offers_response" > "$offer"
offer_id="$(jq -r '.id // empty' "$offer")"

if [[ -z "$offer_id" || "$offer_id" == "null" ]]; then
  echo "No Vast.ai offers matched the search payload for ${name}." >&2
  jq '.' "$search_payload" >&2
  exit 1
fi

printf '%s\n' "$offer_id" > "$offer_id_file"

curl -fsS \
  --request PUT \
  --url "${vast_api_url%/}/api/v0/asks/${offer_id}/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  --header "Content-Type: application/json" \
  --data @"$create_payload" \
  > "$create_response"

instance_id="$(jq -r '.new_contract // empty' "$create_response")"

if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
  echo "Vast.ai did not return new_contract for ${name}." >&2
  jq '.' "$create_response" >&2
  exit 1
fi

printf '%s\n' "$instance_id" > "$instance_id_file"

# Best-effort: capture public_ipaddr + ports now. The instance may not be
# running yet (Vast assigns IP/SSH-host-port asynchronously); scripts/vast_instance_info.sh
# polls reliably if this is incomplete. Never fail the create here.
info_file="$state_dir/instance_info.json"
if curl -fsS \
  --request GET \
  --url "${vast_api_url%/}/api/v0/instances/${instance_id}/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  > "$state_dir/instance_raw.json" 2>/dev/null; then
  jq -n --arg id "$instance_id" --slurpfile inst "$state_dir/instance_raw.json" \
    '{instance_id:$id, status:($inst[0].actual_status // null), public_ipaddr:($inst[0].public_ipaddr // null), ports:($inst[0].ports // null)}' \
    > "$info_file" 2>/dev/null || \
    printf '{"instance_id":"%s","status":null,"public_ipaddr":null,"ports":null}\n' "$instance_id" > "$info_file"
else
  printf '{"instance_id":"%s","status":null,"public_ipaddr":null,"ports":null}\n' "$instance_id" > "$info_file"
fi

echo "Created Vast.ai instance ${instance_id} for ${name} from offer ${offer_id}."
