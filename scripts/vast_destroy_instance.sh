#!/usr/bin/env bash
# Destroy a Vast.ai instance by id (read from <state_dir>/instance_id) and tear
# it down via DELETE /api/v0/instances/{id}/. Idempotent: a missing instance_id
# file, an empty id, OR a 404 (instance already gone — preempted / destroyed
# elsewhere) are all treated as success, so a stale instance_id never fails the
# destroy path (e.g. terraform's destroy provisioner, or `deploy.sh --destroy`
# after a box has already been reaped by Vast).
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
  echo "VAST_API_KEY must be exported before destroy." >&2
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

# Capture the HTTP status code (not -f: we want to inspect 404 ourselves). The
# body goes to destroy_response.json for audit; we branch on http_code.
http_code="$(curl -sS --write-out '%{http_code}' -o "$state_dir/destroy_response.json" \
  --request DELETE \
  --url "${vast_api_url%/}/api/v0/instances/${instance_id}/" \
  --header "Authorization: Bearer ${VAST_API_KEY}" \
  --header "Content-Type: application/json" || true)"

case "$http_code" in
  200)
    echo "Destroyed Vast.ai instance ${instance_id} for ${name} (HTTP 200)."
    ;;
  404)
    # Already gone (preempted / destroyed elsewhere / never existed). Idempotent
    # success — never fail the destroy path on a stale id.
    echo "Instance ${instance_id} for ${name} already gone (HTTP 404); nothing to destroy."
    ;;
  "")
    # curl itself failed (network/DNS). Don't silently swallow a real failure to
    # DELETE a *live* box, but don't hard-fail either — surface it and exit 0 so
    # a transient blip doesn't block a `deploy.sh --destroy` whose box is
    # almost certainly already gone. Re-run --destroy to retry if unsure.
    echo "Vast DELETE for ${instance_id} (${name}): network error reaching the API (HTTP code empty). Assuming already gone; re-run --destroy if the box may still be billing." >&2
    ;;
  *)
    echo "Vast DELETE for ${instance_id} (${name}) failed (HTTP ${http_code})." >&2
    echo "  response: $(cat "$state_dir/destroy_response.json" 2>/dev/null || echo '<empty>')" >&2
    exit 1
    ;;
esac