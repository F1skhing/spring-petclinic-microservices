# Nginx unified entry

The host exposes the Petclinic application only through Nginx:

```text
Browser -> localhost:8080 -> nginx-gateway:80 -> api-gateway:8080
```

The API Gateway and the three business services use `expose` instead of
`ports`. Their application ports remain reachable inside the Compose network
but are not published directly on the host:

- `api-gateway:8080`
- `customers-service:8081`
- `visits-service:8082`
- `vets-service:8083`

Prometheus and the API Gateway continue to use these Docker DNS names. Nginx
is the only host-published entry for application traffic.

## Apply the change

Run these commands from the repository root:

```powershell
docker compose config --quiet
docker compose up -d --force-recreate customers-service visits-service vets-service api-gateway nginx-gateway
docker compose ps
```

## Verify

Check the Nginx health endpoint:

```powershell
Invoke-WebRequest http://localhost:8080/nginx-health | Select-Object StatusCode, Content
```

Expected result: HTTP 200 with `nginx ok`.

Check that the application still works through Nginx:

```powershell
Invoke-WebRequest http://localhost:8080 | Select-Object StatusCode
```

Expected result: HTTP 200.

Check the published ports:

```powershell
docker compose ps
```

Expected result:

- `nginx-gateway` publishes `0.0.0.0:8080->80/tcp`.
- `api-gateway` shows only `8080/tcp` and has no host mapping.
- `customers-service`, `visits-service`, and `vets-service` show only their
  container ports and have no host mapping.

Confirm that direct host access is blocked:

```powershell
8081, 8082, 8083 | ForEach-Object {
    try {
        Invoke-WebRequest "http://localhost:$_" -TimeoutSec 3 -ErrorAction Stop
        "UNEXPECTED: localhost:$_ is reachable"
    } catch {
        "EXPECTED: localhost:$_ is not published"
    }
}
```

Finally, open `http://localhost:9091/targets` and confirm that
`customers-service`, `visits-service`, and `vets-service` remain `UP`.

Inspect proxy traffic:

```powershell
docker compose logs --tail=50 nginx-gateway
```

Requests to the Petclinic UI should appear in the Nginx access log with an
upstream address ending in `:8080`.

## Roll back

Remove the `nginx-gateway` service, restore `ports: - 8080:8080` on
`api-gateway`, and run:

```powershell
docker compose up -d --force-recreate api-gateway
```
