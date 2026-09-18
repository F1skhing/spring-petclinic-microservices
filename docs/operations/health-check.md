# Automated stack health check

Run the verification script from the repository root after a deployment or
configuration change:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ops\verify-stack.ps1
```

The script verifies:

1. Nginx returns `200` and `nginx ok` from `/nginx-health`.
2. The Petclinic application returns `200` through the Nginx entry.
3. The Customers API returns `200` and valid JSON through Nginx and the API
   Gateway.
4. Host ports `8081`, `8082`, and `8083` are not published.
5. Prometheus reports the Customers, Visits, and Vets targets as `up`.

The application entry is a shallow availability check. It can still return
`200` when a downstream service is unavailable. The Customers API check is a
functional dependency check that detects this failure mode.

A successful run exits with code `0`. Any failed check produces exit code `1`,
which makes the script suitable for a CI/CD smoke-test step.

Optional parameters allow the same script to test another environment:

```powershell
.\scripts\ops\verify-stack.ps1 `
  -ApplicationUrl http://server.example:8080 `
  -PrometheusUrl http://server.example:9091
```

For a controlled failure and recovery exercise, follow
[`customer-service-failure-drill.md`](customer-service-failure-drill.md).
