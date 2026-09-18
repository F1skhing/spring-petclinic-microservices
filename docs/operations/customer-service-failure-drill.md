# Customers service failure drill

This drill validates failure detection, diagnosis, recovery, and evidence
collection for `customers-service`. Run all commands from the repository root.

## Safety boundary

- Stop only `customers-service`.
- Do not run `docker compose down -v`.
- Do not delete containers, images, volumes, or application data.

## 1. Record the healthy baseline

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-stack.ps1
$LASTEXITCODE
```

Expected result: all checks pass and the exit code is `0`.

## 2. Inject the failure

```powershell
docker compose stop customers-service
docker compose ps customers-service
```

Wait about 20 seconds so Prometheus can perform another scrape, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-stack.ps1
$LASTEXITCODE
```

Expected result:

- `Nginx health` and `Application entry` can remain `PASS`.
- `Customers API` becomes `FAIL`.
- `Prometheus customers-service` becomes `FAIL` after its next scrape.
- The script exits with code `1`.

This difference demonstrates why a static homepage check cannot replace a
functional dependency check.

## 3. Collect diagnosis evidence

```powershell
docker compose ps
docker compose logs --tail=100 api-gateway
docker compose logs --tail=100 customers-service
```

Also open `http://localhost:9091/targets` and record the Customers target
status and error. The expected root cause is an intentionally stopped
`customers-service`, not an Nginx failure.

## 4. Recover and verify

```powershell
docker compose start customers-service
docker compose ps customers-service
```

Wait until the service has started and registered with Eureka. Then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-stack.ps1
$LASTEXITCODE
```

Expected result: all checks pass again and the exit code is `0`. Prometheus may
need one additional scrape interval before its target returns to `up`.

Do not treat a single recovered signal as full recovery. Prometheus can report
the metrics endpoint as `up` before Eureka and the API Gateway have refreshed
their service-discovery state. Recovery is complete only when Eureka reports
the instance as `UP`, the Customers API succeeds, and the full verification
script exits with code `0`.

## 5. RCA record

Record these fields after the drill:

- Incident: Customers API unavailable.
- Impact: owner-related functions failed; the static application entry remained available.
- Detection: functional API check and Prometheus target health.
- Root cause: `customers-service` was intentionally stopped for the drill.
- Recovery: started the service and waited for registration and monitoring recovery.
- Prevention: retain functional checks and configure an alert for the Customers target.
- Evidence: failed verification output, container status/logs, and successful recovery output.
