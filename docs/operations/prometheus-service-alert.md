# Prometheus service-down alert

The `PetclinicServiceDown` rule monitors the Customers, Visits, and Vets
Prometheus targets. If one remains unavailable for 30 seconds, the alert moves
from `pending` to `firing`.

Prometheus evaluates and displays this alert. It does not send email or chat
notifications until an Alertmanager receiver is configured.

## 1. Build and load the rule

Run from the repository root:

```powershell
docker compose up -d --build --force-recreate prometheus-server
docker compose logs --tail=50 prometheus-server
```

Verify the healthy baseline:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-alert-rule.ps1 `
  -ExpectedState inactive
$LASTEXITCODE
```

The script should pass with exit code `0`. The rule is also visible at
`http://localhost:9091/alerts`. Immediately after a Prometheus restart, rule
health can briefly be `unknown`; the script polls until the first successful
evaluation or the configured timeout.

## 2. Trigger the alert

```powershell
docker compose stop customers-service
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-alert-rule.ps1 `
  -ExpectedState firing `
  -TargetJob customers-service `
  -WaitSeconds 180
$LASTEXITCODE
```

The script polls every 5 seconds and exits when the rule reaches `firing`.
`-WaitSeconds` is only the timeout. It must be larger than the worst-case sum
of scrape detection, rule evaluation, and the rule's `for` duration. Capture
the terminal output and the Prometheus Alerts page as evidence.

## 3. Recover the service and alert

```powershell
docker compose start customers-service
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-alert-rule.ps1 `
  -ExpectedState inactive `
  -WaitSeconds 180
$LASTEXITCODE
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-stack.ps1
$LASTEXITCODE
```

The alert rule and full stack checks should pass with exit code `0`.
