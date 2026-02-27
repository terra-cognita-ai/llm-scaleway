# llm-scaleway

Run `mistralai/Ministral-3-8B-Instruct-2512` with `vLLM` on a Scaleway `L4-1-24G` GPU instance.

This repo includes:
- `docker-compose.yml` for the vLLM runtime
- `.env.example` for model/runtime/deploy variables
- `scripts/deploy-scaleway.sh` to provision + deploy using the Scaleway CLI
- `scripts/redeploy-scaleway.sh` to update container config/image on an existing instance
- `scripts/destroy-scaleway.sh` to delete the GPU instance (and attached volumes)

## Prerequisites

- Scaleway account with GPU quota in your target zone
- `scw` CLI installed and configured (`scw init`)
- Local tools: `bash`, `ssh`, `scp`, `python3`
- SSH key available in your Scaleway account

## Quick start

1. Copy environment file:

```bash
cp .env.example .env
```

2. Edit `.env` (at least verify these):
	 - `SCW_ZONE` (example: `fr-par-2`)
	 - `SCW_COMMERCIAL_TYPE` (default: `L4-1-24G`)
	 - `SCW_SERVER_NAME`
	 - `SCW_SERVER_IP` (`dynamic` by default, avoids billable flexible IP allocation)
	 - `SCW_DETACH_PUBLIC_IP_AFTER_DEPLOY` (`true` to bootstrap over public IP then detach it automatically)
	 - `SCW_PRIVATE_NETWORK_NAME` (required when `SCW_SERVER_IP=none`, e.g. `schligler-ia-app`)
	 - `VLLM_IMAGE` (defaults to `vllm/vllm-openai:latest`, can be pinned)
	 - `VLLM_BIND_IP` (host interface bind, default `0.0.0.0`)
	 - `VLLM_ALLOWED_CIDRS` (comma-separated source CIDRs allowed to call the API)
	 - `VLLM_ALLOWED_CIDRS_FROM_SERVER_NAME` (optional instance name to auto-add as `/32`, e.g. `schligler-ia-parser`)
	 - `VLLM_READY_TIMEOUT_SEC` (max wait before deploy fails if `/v1/models` is not ready)
	 - `SCW_SSH_PUBLIC_KEY_PATH` (public key injected via cloud-init)
	 - `SCW_SSH_PRIVATE_KEY_PATH` (private key used by local `ssh/scp`)
	 - `HUGGING_FACE_HUB_TOKEN` (if model access requires it)

3. Run deployment:

```bash
chmod +x scripts/deploy-scaleway.sh
./scripts/deploy-scaleway.sh
```

The script will:
- create the GPU server only if it does not already exist
- wait for readiness and resolve public IP
- install Docker + NVIDIA container toolkit remotely
- upload `docker-compose.yml` + generated env
- start `vllm/vllm-openai` as a detached container

If an instance with `SCW_SERVER_NAME` already exists, deployment stops with an error (to prevent deploying the same instance twice).

## Redeploy in place

To update runtime config/model/image without destroying the instance:

```bash
chmod +x scripts/redeploy-scaleway.sh
./scripts/redeploy-scaleway.sh
```

This script requires an existing instance with `SCW_SERVER_NAME` and will only:
- upload `docker-compose.yml` and runtime `.env`
- run `docker compose pull`
- run `docker compose up -d`

## Access control

You can restrict who can call the vLLM API with `.env`:

```bash
VLLM_BIND_IP=0.0.0.0
VLLM_ALLOWED_CIDRS=163.172.162.19/32
```

- `VLLM_ALLOWED_CIDRS` is a comma-separated CIDR allowlist applied on the server firewall for `VLLM_PORT`.
- `/32` means one exact source IP.
- Set `VLLM_ALLOWED_CIDRS_FROM_SERVER_NAME=schligler-ia-parser` to auto-resolve and append `/32` during deploy/redeploy.
- When `SCW_PRIVATE_NETWORK_NAME` is set, scripts prefer that instance private IPv4 on this network; otherwise they fall back to public IP.
- Keep it empty only if you intentionally want public access.

After updating `.env`, apply changes without recreating the instance:

```bash
./scripts/redeploy-scaleway.sh
```

Expected output includes:

```text
Applied VLLM allowlist on port 8000: 163.172.162.19/32
```

## Test endpoint

After deploy, test OpenAI-compatible API:

```bash
curl http://<SERVER_IP>:8000/v1/chat/completions \
	-H "Content-Type: application/json" \
	-d '{
		"model": "ministral-8b",
		"messages": [
			{"role": "system", "content": "You are a helpful assistant."},
			{"role": "user", "content": "Explain KV cache like I am 10."}
		],
		"temperature": 0.3
	}'
```

## Runtime tuning (L4 suggestions)

Configured defaults are production-leaning:
- `GPU_MEMORY_UTILIZATION=0.90`
- `MAX_MODEL_LEN=8192`
- `MAX_NUM_SEQS=24`

If you see OOM under load, lower:
- `GPU_MEMORY_UTILIZATION` to `0.85`
- `MAX_MODEL_LEN` to `4096`

## Notes

- `SCW_IMAGE` can be left empty: deploy script auto-resolves a Ubuntu 22.04 image in the selected zone.
- `SCW_SERVER_IP=dynamic` avoids creating a billable flexible IP while still exposing a public dynamic IP for SSH/API access.
- Simple private final state: set `SCW_SERVER_IP=dynamic` and `SCW_DETACH_PUBLIC_IP_AFTER_DEPLOY=true` so deploy can bootstrap, then removes public IP automatically.
- Set `SCW_SERVER_IP=none` for no public IP; in that mode set `SCW_PRIVATE_NETWORK_NAME` so deploy attaches a private NIC and uses the private IP for SSH/bootstrap.
- If private-network lookup needs to be forced, set `SCW_REGION` (defaults to region derived from `SCW_ZONE`, e.g. `fr-par-1` -> `fr-par`).
- Access to port `8000` can be restricted directly from `.env` with `VLLM_ALLOWED_CIDRS`.
- Example for a single caller instance: `VLLM_ALLOWED_CIDRS=51.15.12.34/32`
- Example for a private subnet: `VLLM_ALLOWED_CIDRS=10.0.0.0/24`
- Leave `VLLM_ALLOWED_CIDRS` empty only if you explicitly want open access.
- For `Ubuntu Noble GPU OS 13 (Nvidia)`, this setup pins `LD_LIBRARY_PATH` in `docker-compose.yml` to avoid CUDA error `803` (`unsupported display driver / cuda driver combination`) caused by CUDA compat library precedence.

## Destroy instance

To tear down the GPU server, its volumes, and any attached flexible/public IP resources:

```bash
chmod +x scripts/destroy-scaleway.sh
./scripts/destroy-scaleway.sh
```