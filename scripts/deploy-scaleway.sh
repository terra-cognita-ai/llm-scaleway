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
SCW_COMMERCIAL_TYPE="${SCW_COMMERCIAL_TYPE:-L4-1-24G}"
SCW_IMAGE="${SCW_IMAGE:-}"
SCW_SERVER_NAME="${SCW_SERVER_NAME:-llm-ministral-vllm}"
SCW_VOLUME_SIZE_GB="${SCW_VOLUME_SIZE_GB:-80}"
SCW_ROOT_VOLUME="${SCW_ROOT_VOLUME:-sbs:${SCW_VOLUME_SIZE_GB}GB}"
SCW_SSH_USER="${SCW_SSH_USER:-root}"
SCW_SSH_PUBLIC_KEY_PATH="${SCW_SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/scaleway.pub}"
SCW_SSH_PRIVATE_KEY_PATH="${SCW_SSH_PRIVATE_KEY_PATH:-}"
SCW_IMAGE_FALLBACK="${SCW_IMAGE_FALLBACK:-ubuntu_jammy}"

MODEL_ID="${MODEL_ID:-mistralai/Ministral-3-8B-Instruct-2512}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-ministral-8b}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
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

if [[ -z "${SCW_IMAGE}" ]]; then
  echo "Resolving latest Ubuntu 22.04 image for zone ${SCW_ZONE}"
  IMAGES_JSON="$(scw instance image list zone="${SCW_ZONE}" -o json)"
  SCW_IMAGE="$(printf '%s' "${IMAGES_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); imgs=d.get("images", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); out=""; names=("ubuntu jammy", "ubuntu 22.04");
for img in imgs:
    name=(img.get("name") or "").lower()
    arch=(img.get("arch") or "")
    if arch in ("x86_64", "") and any(n in name for n in names):
        out=img.get("id", "")
        if out:
            break
print(out)')"

  if [[ -z "${SCW_IMAGE}" ]]; then
    echo "Could not auto-resolve Ubuntu image in ${SCW_ZONE}."
    echo "Falling back to image alias: ${SCW_IMAGE_FALLBACK}"
    SCW_IMAGE="${SCW_IMAGE_FALLBACK}"
  fi
fi

echo "Using image: ${SCW_IMAGE}"

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

CLOUD_INIT_ARG=""
if [[ -f "${SCW_SSH_PUBLIC_KEY_PATH}" ]]; then
  echo "Using SSH public key: ${SCW_SSH_PUBLIC_KEY_PATH}"
  SSH_PUBLIC_KEY_CONTENT="$(<"${SCW_SSH_PUBLIC_KEY_PATH}")"
  TMP_CLOUD_INIT_FILE="$(mktemp)"
  cat > "${TMP_CLOUD_INIT_FILE}" <<EOF
#cloud-config
users:
  - default
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY_CONTENT}
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY_CONTENT}
ssh_pwauth: false
EOF
  CLOUD_INIT_ARG="cloud-init=@${TMP_CLOUD_INIT_FILE}"
else
  echo "Warning: SSH public key file not found at ${SCW_SSH_PUBLIC_KEY_PATH}" >&2
  echo "Server may be unreachable via SSH after creation." >&2
fi

echo "Checking if server exists: ${SCW_SERVER_NAME}"
SERVER_LIST_JSON="$(scw instance server list zone="${SCW_ZONE}" name="${SCW_SERVER_NAME}" -o json)"
SERVER_MATCH_COUNT="$(printf '%s' "${SERVER_LIST_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); items=d.get("servers", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); print(len(items))')"

if [[ "${SERVER_MATCH_COUNT}" != "0" ]]; then
  if [[ "${SERVER_MATCH_COUNT}" != "1" ]]; then
    echo "Found ${SERVER_MATCH_COUNT} servers named ${SCW_SERVER_NAME} in ${SCW_ZONE}." >&2
    echo "Resolve duplicates first to avoid deploying to the wrong host." >&2
    exit 1
  fi

  EXISTING_SERVER_ID="$(printf '%s' "${SERVER_LIST_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); items=d.get("servers", []) if isinstance(d, dict) else (d if isinstance(d, list) else []); print(items[0]["id"] if items else "")')"
  echo "Server already exists (${EXISTING_SERVER_ID})." >&2
  echo "Refusing to deploy twice. Destroy it first with scripts/destroy-scaleway.sh or change SCW_SERVER_NAME." >&2
  exit 1
fi

echo "Creating new server ${SCW_SERVER_NAME} (${SCW_COMMERCIAL_TYPE}) in ${SCW_ZONE}"
CREATE_JSON="$(scw instance server create \
  zone="${SCW_ZONE}" \
  name="${SCW_SERVER_NAME}" \
  type="${SCW_COMMERCIAL_TYPE}" \
  image="${SCW_IMAGE}" \
  root-volume="${SCW_ROOT_VOLUME}" \
  dynamic-ip-required=true \
  ${CLOUD_INIT_ARG} \
  -o json)"
SERVER_ID="$(printf '%s' "${CREATE_JSON}" | python3 -c 'import sys, json; d=json.load(sys.stdin); out="";
if isinstance(d, dict):
    if isinstance(d.get("server"), dict):
        out=d["server"].get("id", "")
    elif d.get("id"):
        out=d.get("id", "")
elif isinstance(d, list) and d and isinstance(d[0], dict):
    out=d[0].get("id", "")
print(out)')"

if [[ -z "${SERVER_ID}" ]]; then
  echo "Could not parse server ID from create response." >&2
  [[ -n "${TMP_CLOUD_INIT_FILE:-}" ]] && rm -f "${TMP_CLOUD_INIT_FILE}"
  exit 1
fi

[[ -n "${TMP_CLOUD_INIT_FILE:-}" ]] && rm -f "${TMP_CLOUD_INIT_FILE}"

echo "Waiting for server to be ready..."
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
  echo "Check that SCW_SSH_PUBLIC_KEY_PATH points to a valid public key and SCW_SSH_USER is correct." >&2
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

echo "Installing Docker + NVIDIA runtime on remote host"
ssh "${SSH_BASE_ARGS[@]}" "${SCW_SSH_USER}@${SERVER_IP}" 'bash -s' <<'REMOTE'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit

if command -v nvidia-ctk >/dev/null 2>&1; then
  nvidia-ctk runtime configure --runtime=docker || true
  systemctl restart docker || true
fi

mkdir -p /opt/llm-scaleway
REMOTE

echo "Uploading compose and env files"
scp "${SCP_BASE_ARGS[@]}" docker-compose.yml "${SCW_SSH_USER}@${SERVER_IP}:/opt/llm-scaleway/docker-compose.yml"
scp "${SCP_BASE_ARGS[@]}" "${TMP_ENV_FILE}" "${SCW_SSH_USER}@${SERVER_IP}:/opt/llm-scaleway/.env"
rm -f "${TMP_ENV_FILE}"

echo "Starting vLLM container"
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
echo "Deployment complete."
echo "OpenAI-compatible endpoint: http://${SERVER_IP}:${VLLM_PORT}/v1"
echo "Test with:"
echo "curl http://${SERVER_IP}:${VLLM_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
