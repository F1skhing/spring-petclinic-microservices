# Alertmanager integration

Alertmanager receives alerts from Prometheus, groups them by alert name and
service job, and tracks their active and resolved lifecycle. The local
`operations` receiver intentionally has no external email or chat credentials.

## 1. Start the alerting pipeline

Run from the repository root:

```powershell
docker compose up -d --build --force-recreate alertmanager prometheus-server
docker compose logs --tail=50 alertmanager prometheus-server
```

Verify readiness, Prometheus connectivity, and the healthy empty baseline:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-alertmanager.ps1 `
  -ExpectedAlert absent
$LASTEXITCODE
```

Expected result: the script passes with exit code `0`. The Alertmanager UI is
available at `http://localhost:9093`.

## 2. Verify alert delivery

```powershell
docker compose stop customers-service
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-alertmanager.ps1 `
  -ExpectedAlert present `
  -TargetJob customers-service `
  -WaitSeconds 180
$LASTEXITCODE
```

The script polls every 5 seconds and exits as soon as the alert arrives. The
180-second value is a timeout, not a fixed delay. It covers the current scrape
and evaluation intervals, the rule's 30-second `for` duration, and
Alertmanager's `group_wait`. If those settings increase, increase
`-WaitSeconds` accordingly.

## 3. Verify resolution

```powershell
docker compose start customers-service
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-alertmanager.ps1 `
  -ExpectedAlert absent `
  -WaitSeconds 300
$LASTEXITCODE
powershell -ExecutionPolicy Bypass -File .\scripts\ops\wait-stack-ready.ps1 `
  -WaitSeconds 300 `
  -PollIntervalSeconds 5
$LASTEXITCODE
```

The recovery script polls the Customers API, Eureka registration, and
Prometheus every 5 seconds for up to 5 minutes. It exits immediately when all
three signals are ready, then runs the full stack verification. This prevents
an already-resolved alert from masking a Gateway service-discovery delay.

Both scripts should pass with exit code `0`. External notification delivery is
a separate step because it requires user-owned receiver credentials.
