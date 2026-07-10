#!/usr/bin/env bash
set -euo pipefail

name=""
vast_api_url="https://console.vast.ai"
search_payload=""
create_payload=""
state_dir=""
template_image=""
yes=0   # --yes / VAST_CONFIRM_RENT=1 skips the confirm-before-spend prompt

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
    --yes)
      # Skip the confirm-before-spend prompt (automation / re-run after review).
      yes=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Allow deploy.sh to pre-consent via env (threaded through terraform apply ->
# local-exec, which inherits this process's exported environment).
[[ "${VAST_CONFIRM_RENT:-0}" == "1" ]] && yes=1

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

base_payload="$(cat "$search_payload")"
offers_response="$state_dir/offers.json"
offer="$state_dir/offer.json"
offer_id_file="$state_dir/offer_id"
create_response="$state_dir/create_response.json"
instance_id_file="$state_dir/instance_id"
used_payload_file="$state_dir/search_payload_used.json"

# ---- best-price rent with a fallback ladder (p3) ----
# Search /api/v0/bundles/ with the chosen options. If it returns 0 offers,
# auto-relax IN ORDER — raise the $/hr cap -> drop the datacenter requirement
# -> broaden the GPU name whitelist (the VRAM/disk/RAM floors are kept) ->
# on-demand/reserved -> bid (interruptible, cheapest) — until an offer is
# found. Each step is CUMULATIVE. The confirm-before-spend gate below still
# shows the *actual* cheapest offer from the WINNING search, so a human always
# consents to the real box (and --yes/VAST_CONFIRM_RENT bypasses only the
# prompt, after this ladder has run). $used_payload_file records which option
# set actually rented, for auditability.
search_offers() {  # $1=payload json  $2=out file ; writes the bundles response
  printf '%s' "$1" | curl -sS --request POST \
    --url "${vast_api_url%/}/api/v0/bundles/" \
    --header "Authorization: Bearer ${VAST_API_KEY}" \
    --header "Content-Type: application/json" \
    --data @- > "$2" 2>/dev/null || true
}

# ---- effective-price normalization (show both, pick cheaper) ----
# The Vast web UI shows TWO prices the raw dph_total (gross on-demand) hides:
#   - discounted on-demand: discounted_dph_total / search.discountedTotalPerHour
#     (= totalHour − discountTotalHour, after discount_rate / credit_discount_max;
#     typically 5–15% off gross).
#   - spot/bid: min_bid (interruptible; the web's bid column — often far lower).
# We annotate every offer with ondemand_disc, spot, best=min(ondemand_disc,spot),
# gross, disc_pct so selection/sort/display all use the web-comparable effective
# price. spot is only considered when min_bid is present (null -> on-demand only).
# The API can only filter on gross dph_total, so the dph_total.lte cap stays a
# GROSS cap; the effective price paid is always <= that cap (discount/spot lower).
normalize_offers() {  # $1=in file (bundles response) — rewritten in place with effprice fields
  local tmp; tmp="$(mktemp)"
  jq '.offers |= [ .[] | . + {
    gross: .dph_total,
    ondemand_disc: (.discounted_dph_total // .search.discountedTotalPerHour // .dph_total),
    spot: .min_bid,
    best: ( [ (.discounted_dph_total // .search.discountedTotalPerHour // .dph_total),
              (.min_bid // 999999) ] | min ),
    disc_pct: ( if ((.dph_total // 0) | .) > 0
                then ((1 - (((.discounted_dph_total // .search.discountedTotalPerHour // .dph_total)) / .dph_total)) * 100 | . * 10 | round / 10)
                else 0 end )
  } ]' "$1" > "$tmp" && mv -f "$tmp" "$1"
}

# Build the cumulative relaxation ladder (step 0 = the payload as-given).
dph_cap="$(printf '%s' "$base_payload" | jq -r '.dph_total.lte // empty')"
relaxed_cap=""
if [[ -n "$dph_cap" && "$dph_cap" != "null" ]]; then
  # 4x the cap, hard ceiling at 80 $/hr so --yes automation can't rent a runaway.
  relaxed_cap="$(jq -n --argjson c "$dph_cap" '[$c*4, 80] | min')"
fi
cur_type="$(printf '%s' "$base_payload" | jq -r '.type // empty')"

ladder_labels=( "chosen filters (as-given)" )
ladder_filters=( "." )
if [[ -n "$relaxed_cap" ]]; then
  ladder_labels+=( "raise $/hr cap ${dph_cap} -> ${relaxed_cap}" )
  ladder_filters+=( ".dph_total.lte = ${relaxed_cap}" )
fi
ladder_labels+=( "drop datacenter requirement" )
ladder_filters+=( 'del(.datacenter)' )
ladder_labels+=( "broaden GPU list (any GPU name; VRAM floor kept)" )
ladder_filters+=( 'del(.gpu_name)' )
if [[ "$cur_type" == "ondemand" || "$cur_type" == "reserved" ]]; then
  ladder_labels+=( "switch market type ${cur_type} -> bid (interruptible)" )
  ladder_filters+=( '.type = "bid"' )
fi

echo "Searching Vast.ai offers (best price) for ${name}..." >&2
working="$base_payload"
found=0
for i in "${!ladder_filters[@]}"; do
  label="${ladder_labels[$i]}"
  working="$(printf '%s' "$working" | jq -c "${ladder_filters[$i]}")"
  echo "  attempt $((i+1))/${#ladder_filters[@]}: ${label}" >&2
  search_offers "$working" "$offers_response"
  n="$(jq '(.offers // []) | length' "$offers_response" 2>/dev/null || echo 0)"
  if [[ "$n" -gt 0 ]]; then
    echo "  -> ${n} offers found with: ${label}" >&2
    printf '%s' "$working" > "$used_payload_file"
    found=1
    break
  fi
  echo "  -> 0 offers with: ${label}; relaxing further..." >&2
done

if [[ "$found" -ne 1 ]]; then
  echo "No Vast.ai offers matched for ${name} after the full fallback ladder." >&2
  echo "Tried (in order): ${ladder_labels[*]}" >&2
  echo "Base search payload:" >&2
  jq '.' "$search_payload" >&2
  exit 1
fi

# Annotate the winning offers with effective-price fields, then pick the cheapest
# by BEST (min of discounted on-demand + spot), not gross dph_total. This makes
# the curated pick match the Vast web UI's "best price".
normalize_offers "$offers_response"
jq '[.offers[]] | sort_by(.best) | .[0]' "$offers_response" > "$offer"
offer_id="$(jq -r '.id // empty' "$offer")"
if [[ -z "$offer_id" || "$offer_id" == "null" ]]; then
  echo "Search returned offers but no cheapest id could be parsed." >&2
  jq '.' "$offers_response" >&2
  exit 1
fi

printf '%s\n' "$offer_id" > "$offer_id_file"

# ---- helpers: display offers in human units ----
# Vast offer units (observed): gpu_ram = MB (per GPU), cpu_ram = MB, disk_space
# = GB, dph_total = $/hr. The old gate mislabeled cpu_ram as "bytes"; it's MB.
# Print one offer (json object) as the rent summary. $1=object json, $2=header
show_offer() {
  local o="$1" hdr="$2"
  local gpu ngpu vram ram disk dph rel dc geo best ods spot gross discp basis
  gpu="$(printf '%s' "$o"  | jq -r '.gpu_name // "n/a"')"
  ngpu="$(printf '%s' "$o" | jq -r '.num_gpus // "?"')"
  vram="$(printf '%s' "$o" | jq -r '.gpu_ram  // 0' | awk '{printf "%.0f", $1/1024}')"
  ram="$(printf '%s' "$o"  | jq -r '.cpu_ram  // 0' | awk '{printf "%.0f", $1/1024}')"
  disk="$(printf '%s' "$o" | jq -r '.disk_space // "?"')"
  dph="$(printf '%s' "$o"  | jq -r '.dph_total // 0' | awk '{printf "%.2f", $1}')"
  rel="$(printf '%s' "$o"  | jq -r '.reliability // "?"')"
  dc="$(printf '%s' "$o"   | jq -r '.datacenter // "n/a"')"
  geo="$(printf '%s' "$o"  | jq -r '.geolocation // .country // "?"')"
  # Effective-price fields (added by normalize_offers; fall back to gross if absent).
  best="$(printf '%s' "$o"  | jq -r '.best // .dph_total // 0' | awk '{printf "%.3f", $1}')"
  ods="$(printf '%s' "$o"   | jq -r '.ondemand_disc // .dph_total // 0' | awk '{printf "%.3f", $1}')"
  spot="$(printf '%s' "$o"  | jq -r 'if .spot == null then "—" else (.spot | tostring) end')"
  gross="$(printf '%s' "$o" | jq -r '.gross // .dph_total // 0' | awk '{printf "%.3f", $1}')"
  discp="$(printf '%s' "$o" | jq -r '.disc_pct // 0' | awk '{printf "%.1f", $1}')"
  # Which basis won the min() — shows the operator what they're actually paying.
  basis="$(printf '%s' "$o" | jq -r 'if (.spot // null) != null and (.spot <= (.ondemand_disc // .dph_total)) then "spot/bid (interruptible)" else "on-demand (discounted)" end')"
  echo "  ── ${hdr} ────────────────────────────────────────────────" >&2
  printf '    GPU          : %s × %s  (%s GB VRAM)\n' "$ngpu" "$gpu" "$vram" >&2
  printf '    host RAM     : %s GB\n' "$ram" >&2
  printf '    disk         : %s GB\n' "$disk" >&2
  printf '    $/hour       : %s  (effective: %s)\n' "$dph" "$best" >&2
  printf '      on-demand  : $%s/hr discounted (gross $%s, %s%% off)\n' "$ods" "$gross" "$discp" >&2
  if [[ "$spot" == "—" ]]; then
    printf '      spot/bid   : (none offered)\n' >&2
  else
    printf '      spot/bid   : $%s/hr (interruptible)\n' "$spot" >&2
  fi
  printf '      basis      : %s\n' "$basis" >&2
  printf '    reliability  : %s   datacenter: %s   geo: %s\n' "$rel" "$dc" "$geo" >&2
}

# Browse the whole suitable market, cheapest-first, paginated, and let the human
# pick one by number. Relaxes the SOFT prefs (gpu_name whitelist [already gone
# by default], datacenter, reliability, host-RAM floor) but KEEPS the load-bearing
# gpu_ram/disk/num_gpus filters, so every listed box actually fits the models.
# (24 GB cards are still excluded — they can't hold a 22 GB model; that's the
# gpu_ram floor doing its job, not a missing option.) Sets $offer_id / $offer /
# $offer_id_file to the pick; returns 1 on no-pick, 0 + prints confirmation.
browse_and_pick() {
  local broad broad_resp sorted total per page lo hi bn pick picked final pages
  broad="$(printf '%s' "$base_payload" | jq -c 'del(.gpu_name, .datacenter, .reliability, .cpu_ram) | .limit = 200')"
  echo "  Browsing the full suitable market — gpu_ram/disk/num_gpus kept," >&2
  echo "  datacenter/reliability/host-RAM relaxed. Host RAM is shown per row;" >&2
  echo "  pick one with RAM >= your largest model (~22 GB+) or the pull may fail." >&2
  broad_resp="$state_dir/offers_browse.json"
  search_offers "$broad" "$broad_resp"
  normalize_offers "$broad_resp"
  bn="$(jq '(.offers // []) | length' "$broad_resp" 2>/dev/null || echo 0)"
  if [[ "$bn" -eq 0 ]]; then
    echo "  No offers even with the prefs relaxed; staying on the curated pick." >&2
    return 1
  fi
  sorted="$state_dir/offers_sorted.json"
  jq '[.offers[] | {id, gpu_name, num_gpus, gpu_ram, cpu_ram, disk_space, dph_total, ondemand_disc, spot, best, reliability, datacenter, country:(.geolocation//.country//"?")}] | sort_by(.best)' "$broad_resp" > "$sorted"
  total="$(jq 'length' "$sorted")"
  pages=$(( (total + 9) / 10 ))
  echo "  ${total} offers, cheapest-first by EFFECTIVE price (min of on-demand-disc + spot), 10 per page." >&2
  per=10; page=0; picked=""
  while true; do
    lo=$((page*per)); hi=$((lo+per-1)); (( hi >= total )) && hi=$((total-1))
    echo "  ── page $((page+1))/${pages} — offers #${lo+1}–#${hi+1} of ${total} ──" >&2
    jq -r --argjson lo "$lo" --argjson hi "$hi" '
      def f2: (. * 100 | round | . / 100 | tostring);
      .[($lo):($hi+1)] | to_entries[] |
      "  #\(.key+$lo+1)  offer \(.value.id)  \(.value.gpu_name) × \(.value.num_gpus)  \(.value.gpu_ram | . / 1024 + 0.5 | floor)GB VRAM  \(.value.cpu_ram | . / 1024 + 0.5 | floor)GB RAM  \(.value.disk_space)GB disk  best=$\(.value.best|f2)/hr  ondem=$\(.value.ondemand_disc|f2)  spot=\(if .value.spot == null then "—" else ("$" + (.value.spot|f2)) end)  rel=\(.value.reliability)  dc=\(.value.datacenter)  \(.value.country)"
    ' "$sorted" >&2
    echo "  (pick #  ·  n=next  ·  p=prev  ·  q=quit browse)" >&2
    read -r -p "  > " pick
    case "$pick" in
      q|Q|quit) echo "  Leaving browse (no pick)." >&2; return 1 ;;
      n|N|next) page=$((page+1)); (( page >= pages )) && page=$((pages-1)); continue ;;
      p|P|prev) page=$((page-1)); (( page < 0 )) && page=0; continue ;;
      *)
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= total )); then
          picked="$pick"; break
        fi
        echo "  '$pick' isn't a number 1–${total}, n, p, or q." >&2
        continue ;;
    esac
  done
  offer_id="$(jq -r --argjson i "$((picked-1))" '.[$i].id' "$sorted")"
  jq --argjson i "$((picked-1))" '.[$i]' "$sorted" > "$offer"
  printf '%s\n' "$offer_id" > "$offer_id_file"
  echo "  You picked offer ${offer_id}." >&2
  show_offer "$(cat "$offer")" "renting your pick (Vast.ai offer ${offer_id})"
  read -r -p "  Confirm rent of this box? [y/N] " final
  case "$final" in
    y|Y|yes|YES) echo "  confirmed — renting offer ${offer_id}." >&2; return 0 ;;
    *) echo "  aborted — no instance rented (no spend)." >&2; exit 1 ;;
  esac
}

# ---- blast-surface gate: confirm the actual selected offer before the PUT ----
# The PUT /api/v0/asks/<offer>/ is the one call that spends money. We block it
# here until the human has seen the *real* cheapest offer and consented. --yes /
# VAST_CONFIRM_RENT=1 skips the prompt; a non-interactive run without consent
# ABORTS before any spend. Answering 'b' (browse) relaxes the soft prefs and lets
# you page through the whole suitable market to pick the best cost yourself.
if [[ "$yes" != "1" ]]; then
  img_lbl="${template_image:-$(jq -r '.image // "n/a"' "$create_payload")}"
  mtype="$(jq -r '.type // "n/a"' "$used_payload_file" 2>/dev/null || jq -r '.type // "n/a"' "$search_payload")"
  show_offer "$(cat "$offer")" "about to rent (Vast.ai offer ${offer_id}) — cheapest match"
  printf '    label        : %s\n    image        : %s\n    market type  : %s   (ondemand=stable, bid=interruptible/cheapest, reserved)\n' "$name" "$img_lbl" "$mtype" >&2
  if [[ -n "$dph_cap" && "$dph_cap" != "null" ]]; then
    printf '    $/hr cap     : %s (GROSS dph_total — the API can only filter gross;\n                    the EFFECTIVE price paid is at or below this due to discount/spot)\n' "$dph_cap" >&2
  fi
  echo "  ─────────────────────────────────────────────────────────────────" >&2
  echo "  next-cheapest curated matches (for sanity-check, by effective price):" >&2
  jq -r '.offers | sort_by(.best) | .[1:3][] | "    offer \(.id): \(.gpu_name) × \(.num_gpus)  best=$\(.best|(. * 100|round/100))  ondem=$\(.ondemand_disc|(. * 100|round/100))  spot=\(if .spot == null then "—" else ("$" + (.spot|(. * 100|round/100|tostring))) end)"' "$offers_response" >&2 || true
  echo >&2

  if [[ ! -t 0 ]]; then
    echo "  Non-interactive run with no --yes/VAST_CONFIRM_RENT=1: NOT renting (no spend)." >&2
    echo "  Re-run: scripts/deploy.sh --confirm-rent   (or export VAST_CONFIRM_RENT=1)" >&2
    exit 1
  fi

  while true; do
    read -r -p "  Rent this box now? [y/N] (b=browse all offers, q=quit) " confirm
    case "$confirm" in
      y|Y|yes|YES)
        echo "  confirmed — renting offer ${offer_id}." >&2
        break ;;
      b|B|browse)
        if browse_and_pick; then break; else continue; fi ;;
      q|Q|quit)
        echo "  aborted — no instance rented (no spend)." >&2; exit 1 ;;
      *)
        echo "  aborted — no instance rented (no spend)." >&2; exit 1 ;;
    esac
  done
fi

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
# polls reliably if this is incomplete. Never fail the create here. Use the v1
# list-by-id helper (v0 single-instance GET is deprecated; v1 has no single route).
info_file="$state_dir/instance_info.json"
export VAST_API_URL="$vast_api_url"
if raw="$(scripts/vast_list_instances_json.sh --id "$instance_id" 2>/dev/null)" && \
   one="$(printf '%s' "$raw" | jq -c '.instances[0] // empty' 2>/dev/null)" && [[ -n "$one" ]]; then
  printf '%s' "$one" | jq -c '{instance_id:.id, status:.actual_status, public_ipaddr:.public_ipaddr, ports:.ports, ssh_host_port:.ssh_host_port}' \
    > "$info_file" 2>/dev/null || \
    printf '{"instance_id":"%s","status":null,"public_ipaddr":null,"ports":null,"ssh_host_port":null}\n' "$instance_id" > "$info_file"
else
  printf '{"instance_id":"%s","status":null,"public_ipaddr":null,"ports":null,"ssh_host_port":null}\n' "$instance_id" > "$info_file"
fi

echo "Created Vast.ai instance ${instance_id} for ${name} from offer ${offer_id}."
