#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd scw
require_cmd python3

SCW_ZONE="${SCW_ZONE:-fr-par-2}"
SCW_SERVER_NAME="${SCW_SERVER_NAME:-llm-ministral-vllm}"

if ! scw info >/dev/null 2>&1; then
  echo "Scaleway CLI is not configured. Run: scw init" >&2
  exit 1
fi

echo "Looking up server: ${SCW_SERVER_NAME} in ${SCW_ZONE}"
SERVER_LIST_JSON="$(scw instance server list zone="${SCW_ZONE}" name="${SCW_SERVER_NAME}" -o json)"
SERVER_MATCH_COUNT="$(printf '%s' "${SERVER_LIST_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); items=d.get("servers", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); print(len(items))')"

if [[ "${SERVER_MATCH_COUNT}" == "0" ]]; then
  echo "No server found named ${SCW_SERVER_NAME} in ${SCW_ZONE}. Nothing to destroy."
  exit 0
fi

if [[ "${SERVER_MATCH_COUNT}" != "1" ]]; then
  echo "Found ${SERVER_MATCH_COUNT} servers named ${SCW_SERVER_NAME} in ${SCW_ZONE}." >&2
  echo "Please disambiguate manually with: scw instance server list zone=${SCW_ZONE}" >&2
  exit 1
fi

SERVER_ID="$(printf '%s' "${SERVER_LIST_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); items=d.get("servers", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); print(items[0]["id"] if items else "")')"

SERVER_GET_JSON="$(scw instance server get "${SERVER_ID}" zone="${SCW_ZONE}" -o json)"
SERVER_PUBLIC_IP_IDS="$(printf '%s' "${SERVER_GET_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); server=((d.get("server") if isinstance(d, dict) and isinstance(d.get("server"), dict) else None) or (d if isinstance(d, dict) else {})); ids=[]; p=server.get("public_ip") or {}; 
if isinstance(p, dict) and p.get("id"): ids.append(str(p.get("id"))); 
for item in (server.get("public_ips") or []):
  if isinstance(item, dict) and item.get("id"):
    ids.append(str(item.get("id")))
seen=set(); out=[]
for ip_id in ids:
  if ip_id not in seen:
    seen.add(ip_id)
    out.append(ip_id)
print("\n".join(out))')"

echo "Deleting server ${SCW_SERVER_NAME} (${SERVER_ID})"
SERVER_STATE="$(printf '%s' "${SERVER_GET_JSON}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("state") if isinstance(d,dict) else "") or "")')"

if [[ "${SERVER_STATE}" == "running" || "${SERVER_STATE}" == "starting" ]]; then
  echo "Server state is ${SERVER_STATE}, powering off first"
  scw instance server stop "${SERVER_ID}" zone="${SCW_ZONE}" >/dev/null
  scw instance server wait "${SERVER_ID}" zone="${SCW_ZONE}" >/dev/null
fi

scw instance server delete "${SERVER_ID}" zone="${SCW_ZONE}" with-volumes=all

if [[ -n "${SERVER_PUBLIC_IP_IDS}" ]]; then
  echo "Deleting attached public/flexible IP resource(s)"
  while IFS= read -r IP_ID; do
    [[ -z "${IP_ID}" ]] && continue
    if scw instance ip delete "${IP_ID}" zone="${SCW_ZONE}" >/dev/null 2>&1; then
      echo "Deleted IP resource ${IP_ID}"
    else
      echo "Warning: could not delete IP resource ${IP_ID}. It may already be released or not deletable." >&2
    fi
  done <<< "${SERVER_PUBLIC_IP_IDS}"
fi

echo "Destroyed ${SCW_SERVER_NAME} (${SERVER_ID}) in ${SCW_ZONE}."
