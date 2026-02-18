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
require_cmd ssh
require_cmd scp
require_cmd python3
require_cmd ssh-keygen

SCW_ZONE="${SCW_ZONE:-fr-par-2}"
SCW_SERVER_NAME="${SCW_SERVER_NAME:-llm-ministral-vllm}"
SCW_SSH_USER="${SCW_SSH_USER:-root}"
SCW_SSH_PRIVATE_KEY_PATH="${SCW_SSH_PRIVATE_KEY_PATH:-}"

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
MODEL_ID="${MODEL_ID:-mistralai/Ministral-3-8B-Instruct-2512}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-ministral-8b}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_BIND_IP="${VLLM_BIND_IP:-0.0.0.0}"
VLLM_ALLOWED_CIDRS="${VLLM_ALLOWED_CIDRS:-}"
VLLM_DTYPE="${VLLM_DTYPE:-float16}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-24}"
HF_CACHE_DIR="${HF_CACHE_DIR:-/data/models}"
HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-}"

if ! scw info >/dev/null 2>&1; then
  echo "Scaleway CLI is not configured. Run: scw init" >&2
  exit 1
fi

SSH_BASE_ARGS=( -o StrictHostKeyChecking=accept-new )
SCP_BASE_ARGS=( -o StrictHostKeyChecking=accept-new )
if [[ -n "${SCW_SSH_PRIVATE_KEY_PATH}" ]]; then
  if [[ ! -f "${SCW_SSH_PRIVATE_KEY_PATH}" ]]; then
    echo "Configured SCW_SSH_PRIVATE_KEY_PATH does not exist: ${SCW_SSH_PRIVATE_KEY_PATH}" >&2
    exit 1
  fi
  SSH_BASE_ARGS+=( -i "${SCW_SSH_PRIVATE_KEY_PATH}" )
  SCP_BASE_ARGS+=( -i "${SCW_SSH_PRIVATE_KEY_PATH}" )
  echo "Using SSH private key: ${SCW_SSH_PRIVATE_KEY_PATH}"
fi

echo "Looking up server: ${SCW_SERVER_NAME} in ${SCW_ZONE}"
SERVER_LIST_JSON="$(scw instance server list zone="${SCW_ZONE}" name="${SCW_SERVER_NAME}" -o json)"
SERVER_MATCH_COUNT="$(printf '%s' "${SERVER_LIST_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); items=d.get("servers", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); print(len(items))')"

if [[ "${SERVER_MATCH_COUNT}" == "0" ]]; then
  echo "No server found named ${SCW_SERVER_NAME} in ${SCW_ZONE}." >&2
  echo "Use scripts/deploy-scaleway.sh for first deployment." >&2
  exit 1
fi

if [[ "${SERVER_MATCH_COUNT}" != "1" ]]; then
  echo "Found ${SERVER_MATCH_COUNT} servers named ${SCW_SERVER_NAME} in ${SCW_ZONE}." >&2
  echo "Resolve duplicates first to avoid redeploying the wrong host." >&2
  exit 1
fi

SERVER_ID="$(printf '%s' "${SERVER_LIST_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); items=d.get("servers", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); print(items[0]["id"] if items else "")')"
SERVER_STATE="$(scw instance server get "${SERVER_ID}" zone="${SCW_ZONE}" -o json | python3 -c 'import sys,json; d=json.load(sys.stdin); server=((d.get("server") if isinstance(d,dict) and isinstance(d.get("server"),dict) else d) if isinstance(d,dict) else {}); print(server.get("state", ""))')"

if [[ "${SERVER_STATE}" == "stopped" || "${SERVER_STATE}" == "stopping" ]]; then
  echo "Server state is ${SERVER_STATE}, powering on"
  scw instance server start "${SERVER_ID}" zone="${SCW_ZONE}" >/dev/null
fi

scw instance server wait "${SERVER_ID}" zone="${SCW_ZONE}" >/dev/null

SERVER_IP=""
for _ in {1..30}; do
  SERVER_JSON="$(scw instance server get "${SERVER_ID}" zone="${SCW_ZONE}" -o json)"
  SERVER_IP="$(printf '%s' "${SERVER_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); server=((d.get("server") if isinstance(d, dict) and isinstance(d.get("server"), dict) else None) or (d if isinstance(d, dict) else {})); ip=((server.get("public_ip") or {}).get("address",""));
if not ip:
    public_ips=server.get("public_ips") or []
    if isinstance(public_ips, list) and public_ips and isinstance(public_ips[0], dict):
        ip=public_ips[0].get("address", "")
print(ip)')"

  if [[ -n "${SERVER_IP}" ]]; then
    break
  fi

  sleep 2
done

if [[ -z "${SERVER_IP}" ]]; then
  echo "Could not resolve server public IP" >&2
  exit 1
fi

echo "Server IP: ${SERVER_IP}"

echo "Refreshing SSH host key for ${SERVER_IP}"
ssh-keygen -R "${SERVER_IP}" >/dev/null 2>&1 || true

echo "Waiting for SSH to become reachable"
for _ in {1..60}; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_BASE_ARGS[@]}" "${SCW_SSH_USER}@${SERVER_IP}" 'echo SSH_OK' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_BASE_ARGS[@]}" "${SCW_SSH_USER}@${SERVER_IP}" 'echo SSH_OK' >/dev/null 2>&1; then
  echo "SSH is not reachable for ${SCW_SSH_USER}@${SERVER_IP}." >&2
  exit 1
fi

echo "Preparing runtime env file"
TMP_ENV_FILE="$(mktemp)"
cat > "${TMP_ENV_FILE}" <<EOF
VLLM_IMAGE=${VLLM_IMAGE}
MODEL_ID=${MODEL_ID}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME}
VLLM_PORT=${VLLM_PORT}
VLLM_BIND_IP=${VLLM_BIND_IP}
VLLM_ALLOWED_CIDRS=${VLLM_ALLOWED_CIDRS}
VLLM_DTYPE=${VLLM_DTYPE}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}
MAX_MODEL_LEN=${MAX_MODEL_LEN}
MAX_NUM_SEQS=${MAX_NUM_SEQS}
HF_CACHE_DIR=${HF_CACHE_DIR}
HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN}
EOF

echo "Uploading compose and env files"
scp "${SCP_BASE_ARGS[@]}" docker-compose.yml "${SCW_SSH_USER}@${SERVER_IP}:/opt/llm-scaleway/docker-compose.yml"
scp "${SCP_BASE_ARGS[@]}" "${TMP_ENV_FILE}" "${SCW_SSH_USER}@${SERVER_IP}:/opt/llm-scaleway/.env"
rm -f "${TMP_ENV_FILE}"

echo "Restarting vLLM container in place"
ssh "${SSH_BASE_ARGS[@]}" "${SCW_SSH_USER}@${SERVER_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd /opt/llm-scaleway
mkdir -p /data/models
set -a
source .env
set +a

docker compose --env-file .env pull
docker compose --env-file .env up -d

apply_vllm_allowlist() {
  local port="${VLLM_PORT:-8000}"
  local allowlist="${VLLM_ALLOWED_CIDRS:-}"

  if ! command -v iptables >/dev/null 2>&1; then
    echo "iptables is not installed; cannot manage allowlist rules." >&2
    exit 1
  fi

  if [[ -z "${allowlist// }" ]]; then
    iptables -D INPUT -p tcp --dport "${port}" -j VLLM_ALLOWLIST 2>/dev/null || true
    iptables -F VLLM_ALLOWLIST 2>/dev/null || true
    echo "No VLLM_ALLOWED_CIDRS configured; port ${port} remains open."
    return 0
  fi

  iptables -N VLLM_ALLOWLIST 2>/dev/null || true
  iptables -F VLLM_ALLOWLIST
  iptables -A VLLM_ALLOWLIST -s 127.0.0.1/32 -j ACCEPT

  IFS=',' read -r -a cidrs <<< "${allowlist}"
  local cidr
  local clean_cidr
  for cidr in "${cidrs[@]}"; do
    clean_cidr="$(echo "${cidr}" | xargs)"
    [[ -z "${clean_cidr}" ]] && continue
    iptables -A VLLM_ALLOWLIST -s "${clean_cidr}" -j ACCEPT
  done

  iptables -A VLLM_ALLOWLIST -j DROP
  iptables -C INPUT -p tcp --dport "${port}" -j VLLM_ALLOWLIST 2>/dev/null || iptables -I INPUT -p tcp --dport "${port}" -j VLLM_ALLOWLIST
  echo "Applied VLLM allowlist on port ${port}: ${allowlist}"
}

apply_vllm_allowlist
REMOTE

echo
echo "Redeploy complete."
echo "OpenAI-compatible endpoint: http://${SERVER_IP}:${VLLM_PORT}/v1"
echo "Test with:"
echo "curl http://${SERVER_IP}:${VLLM_PORT}/v1/models"
