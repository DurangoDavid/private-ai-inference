#!/usr/bin/env bash
set -euo pipefail

name=""
vast_api_url="https://console.vast.ai"
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
  echo "VAST_API_KEY must be exported before terraform destroy." >&2
  exit 1
fi

instance_id_file="$state_dir/instance_id"

if [[ ! -s "$instance_id_file" ]]; then
  echo "No instance_id file found for ${name}; nothing to destroy."
  exit 0
fi

instance_id="$(tr -d '[:space:]' < "$instance_id_file")"

if [[ -z "$instance_id" ]]; then
  echo "Empty instance_id file for ${name}; nothing to destroy."
  exit 0
fi

curl -fsS \
  --request DELETE \
  --url "${vast_api_url%/}/api/v0/instances/${instance_id}/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  --header "Content-Type: application/json" \
  > "$state_dir/destroy_response.json"

echo "Destroyed Vast.ai instance ${instance_id} for ${name}."
