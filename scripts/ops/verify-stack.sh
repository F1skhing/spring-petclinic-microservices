#!/usr/bin/env bash

set -u
set -o pipefail

application_url="${APPLICATION_URL:-http://localhost:8080}"
prometheus_url="${PROMETHEUS_URL:-http://localhost:9091}"
blocked_host="${BLOCKED_HOST:-127.0.0.1}"
blocked_host_ports="${BLOCKED_HOST_PORTS:-8081 8082 8083}"
curl_timeout="${CURL_TIMEOUT:-10}"
failure_count=0

for command_name in curl python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '[FAIL] Dependency - command not found: %s\n' "$command_name"
        exit 2
    fi
done

body_file="$(mktemp)" || exit 2
error_file="$(mktemp)" || {
    rm -f -- "$body_file"
    exit 2
}
trap 'rm -f -- "$body_file" "$error_file"' EXIT

write_result() {
    local status="$1"
    local name="$2"
    local detail="$3"

    printf '[%s] %s - %s\n' "$status" "$name" "$detail"
    if [[ "$status" == "FAIL" ]]; then
        failure_count=$((failure_count + 1))
    fi
}

http_get() {
    local url="$1"

    : >"$body_file"
    : >"$error_file"
    http_code="$(
        curl -sS \
            --max-time "$curl_timeout" \
            -o "$body_file" \
            -w '%{http_code}' \
            "$url" 2>"$error_file"
    )"
    http_exit=$?
    http_error="$(<"$error_file")"
}

http_detail() {
    if [[ -n "$http_error" ]]; then
        printf '%s' "$http_error"
    else
        printf 'curl_exit=%s, HTTP %s' "$http_exit" "$http_code"
    fi
}

http_get "$application_url/nginx-health"
nginx_body="$(<"$body_file")"
if [[ "$http_exit" -eq 0 && "$http_code" == "200" && "$nginx_body" == "nginx ok" ]]; then
    write_result PASS "Nginx health" "HTTP $http_code, body='$nginx_body'"
else
    write_result FAIL "Nginx health" "$(http_detail), body='$nginx_body'"
fi

http_get "$application_url/"
application_bytes="$(wc -c <"$body_file" | tr -d '[:space:]')"
if [[ "$http_exit" -eq 0 && "$http_code" == "200" ]]; then
    write_result PASS "Application entry" "HTTP $http_code, bytes=$application_bytes"
else
    write_result FAIL "Application entry" "$(http_detail), bytes=$application_bytes"
fi

http_get "$application_url/api/customer/owners"
customers_bytes="$(wc -c <"$body_file" | tr -d '[:space:]')"
if [[ "$http_exit" -eq 0 && "$http_code" == "200" ]] && \
    python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$body_file" >/dev/null 2>&1; then
    write_result PASS "Customers API" "HTTP $http_code, valid JSON, bytes=$customers_bytes"
else
    write_result FAIL "Customers API" "$(http_detail), invalid or unavailable JSON, bytes=$customers_bytes"
fi

for port in $blocked_host_ports; do
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        write_result FAIL "Host port value" "invalid port='$port'"
        continue
    fi

    if python3 - "$blocked_host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    connection = socket.create_connection((host, port), timeout=2)
except OSError:
    raise SystemExit(1)
else:
    connection.close()
    raise SystemExit(0)
PY
    then
        write_result FAIL "Host port $port blocked" "reachable=true"
    else
        write_result PASS "Host port $port blocked" "reachable=false"
    fi
done

http_get "$prometheus_url/api/v1/targets"
for job in customers-service visits-service vets-service; do
    if [[ "$http_exit" -ne 0 || "$http_code" != "200" ]]; then
        write_result FAIL "Prometheus $job" "$(http_detail)"
        continue
    fi

    target_detail="$(python3 - "$body_file" "$job" <<'PY'
import json
import sys

path, job = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, json.JSONDecodeError) as exc:
    print(f"invalid JSON: {exc}")
    raise SystemExit(2)

targets = [
    target
    for target in payload.get("data", {}).get("activeTargets", [])
    if target.get("labels", {}).get("job") == job
]
if not targets:
    print("target missing")
    raise SystemExit(1)

health = [str(target.get("health", "unknown")) for target in targets]
print(f"targets={len(targets)}, health={','.join(health)}")
raise SystemExit(0 if all(value == "up" for value in health) else 1)
PY
    )"
    target_exit=$?

    if [[ "$target_exit" -eq 0 ]]; then
        write_result PASS "Prometheus $job" "$target_detail"
    else
        write_result FAIL "Prometheus $job" "$target_detail"
    fi
done

printf '\n'
if [[ "$failure_count" -gt 0 ]]; then
    printf 'Stack verification failed: %s check(s) failed.\n' "$failure_count"
    exit 1
fi

printf 'Stack verification passed: all checks succeeded.\n'
exit 0
