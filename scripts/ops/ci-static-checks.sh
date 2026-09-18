#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-}"

cd "$REPOSITORY_ROOT"

for command_name in bash docker find; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "[FAIL] Required command is missing: $command_name" >&2
    exit 1
  fi
done

if [[ -z "$PROMETHEUS_IMAGE" ]]; then
  if docker image inspect spring-petclinic-microservices-prometheus-server:latest \
    >/dev/null 2>&1; then
    PROMETHEUS_IMAGE="spring-petclinic-microservices-prometheus-server:latest"
  else
    PROMETHEUS_IMAGE="prom/prometheus:v3.1.0"
  fi
fi

# These values are used only while rendering Compose configuration. This script
# never starts services, so no database credentials are created or changed.
export MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-ci-only-root-password}"
export MYSQL_USER="${MYSQL_USER:-petclinic}"
export MYSQL_PASSWORD="${MYSQL_PASSWORD:-ci-only-petclinic-password}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export AZURE_OPENAI_KEY="${AZURE_OPENAI_KEY:-}"
export AZURE_OPENAI_ENDPOINT="${AZURE_OPENAI_ENDPOINT:-}"

echo "[CHECK] Docker Compose configuration"
docker compose config --quiet
echo "[PASS] Docker Compose configuration"

echo "[CHECK] Bash syntax"
mapfile -d '' bash_scripts < <(find scripts/ops -type f -name '*.sh' -print0 | sort -z)
if (( ${#bash_scripts[@]} == 0 )); then
  echo "[FAIL] No Bash scripts were found under scripts/ops." >&2
  exit 1
fi
for script_path in "${bash_scripts[@]}"; do
  bash -n "$script_path"
  echo "[PASS] Bash syntax - $script_path"
done

echo "[CHECK] Prometheus configuration and referenced rules"
echo "[INFO] Prometheus validation image - $PROMETHEUS_IMAGE"
docker run --rm \
  --entrypoint /bin/promtool \
  --volume "$REPOSITORY_ROOT/docker/prometheus:/etc/prometheus:ro" \
  "$PROMETHEUS_IMAGE" \
  check config /etc/prometheus/prometheus.yml
echo "[PASS] Prometheus configuration and referenced rules"

echo "Operations static checks passed."
