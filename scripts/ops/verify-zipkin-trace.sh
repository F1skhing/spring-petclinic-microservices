#!/usr/bin/env bash

set -u
set -o pipefail

APPLICATION_URL="${APPLICATION_URL:-http://localhost:8080}"
ZIPKIN_URL="${ZIPKIN_URL:-http://localhost:9411}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
POLL_SECONDS="${POLL_SECONDS:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_FILE="$(mktemp)"
ERROR_FILE="$(mktemp)"

cleanup() {
  rm -f "$TRACE_FILE" "$ERROR_FILE"
}
trap cleanup EXIT

for command_name in curl python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "[FAIL] Required command is missing: $command_name" >&2
    exit 1
  fi
done

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || (( WAIT_SECONDS < 1 )); then
  echo "[FAIL] WAIT_SECONDS must be a positive integer." >&2
  exit 1
fi

if ! [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || (( POLL_SECONDS < 1 )); then
  echo "[FAIL] POLL_SECONDS must be a positive integer." >&2
  exit 1
fi

health_code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  "$ZIPKIN_URL/health" 2>"$ERROR_FILE")"
if [[ "$health_code" != "200" ]]; then
  echo "[FAIL] Zipkin health - HTTP $health_code, $(<"$ERROR_FILE")" >&2
  exit 1
fi
echo "[PASS] Zipkin health - HTTP 200"

deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS <= deadline )); do
  business_code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "$APPLICATION_URL/api/customer/owners" 2>"$ERROR_FILE")"

  if [[ "$business_code" != "200" ]]; then
    echo "[WAIT] Customers API HTTP $business_code; remaining=$((deadline - SECONDS))s"
    sleep "$POLL_SECONDS"
    continue
  fi

  sleep 2
  if ! curl -fsS --max-time 10 \
    "$ZIPKIN_URL/api/v2/traces?serviceName=api-gateway&limit=50" \
    -o "$TRACE_FILE" 2>"$ERROR_FILE"; then
    echo "[WAIT] Zipkin trace query failed: $(<"$ERROR_FILE"); remaining=$((deadline - SECONDS))s"
    sleep "$POLL_SECONDS"
    continue
  fi

  if trace_summary="$(python3 - "$TRACE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    traces = json.load(stream)

for trace in traces:
    services = sorted({
        span.get("localEndpoint", {}).get("serviceName")
        for span in trace
        if span.get("localEndpoint", {}).get("serviceName")
    })
    has_business_entry = any(
        span.get("tags", {}).get("http.url") == "/api/customer/owners"
        for span in trace
    )
    if has_business_entry and {"api-gateway", "customers-service"}.issubset(services):
        print(
            f"trace_id={trace[0]['traceId']}, spans={len(trace)}, "
            f"services={','.join(services)}"
        )
        raise SystemExit(0)

raise SystemExit(1)
PY
)"; then
    echo "[PASS] Cross-service business trace - $trace_summary"
    if [[ ! -f "$SCRIPT_DIR/verify-stack.sh" ]]; then
      echo "[FAIL] Full-stack verifier is missing: $SCRIPT_DIR/verify-stack.sh" >&2
      exit 1
    fi
    bash "$SCRIPT_DIR/verify-stack.sh"
    stack_exit=$?
    if (( stack_exit != 0 )); then
      echo "[FAIL] Zipkin trace passed, but full-stack verification failed." >&2
      exit "$stack_exit"
    fi
    echo "[PASS] Zipkin trace and full-stack verification succeeded."
    exit 0
  fi

  echo "[WAIT] No Gateway-to-Customers business trace yet; remaining=$((deadline - SECONDS))s"
  sleep "$POLL_SECONDS"
done

echo "[FAIL] No Gateway-to-Customers business trace appeared within ${WAIT_SECONDS}s." >&2
exit 1
