#!/usr/bin/env bash
set -euo pipefail

name=""
vast_api_url="https://console.vast.ai"
search_payload=""
create_payload=""
state_dir=""

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
echo "Created Vast.ai instance ${instance_id} for ${name} from offer ${offer_id}."
