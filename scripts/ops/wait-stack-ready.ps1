[CmdletBinding()]
param(
    [string]$ApplicationUrl = "http://localhost:8080",
    [string]$EurekaUrl = "http://localhost:8761",
    [string]$PrometheusUrl = "http://localhost:9091",
    [string]$ServiceName = "CUSTOMERS-SERVICE",
    [string]$PrometheusJob = "customers-service",
    [int]$WaitSeconds = 300,
    [int]$PollIntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CustomersApi {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "$ApplicationUrl/api/customer/owners" -TimeoutSec 10
        $null = ConvertFrom-Json -InputObject ([string]$response.Content) -ErrorAction Stop
        return [pscustomobject]@{
            Passed = $response.StatusCode -eq 200
            Detail = "HTTP $($response.StatusCode)"
        }
    } catch {
        return [pscustomobject]@{ Passed = $false; Detail = $_.Exception.Message }
    }
}

function Test-EurekaRegistration {
    try {
        $headers = @{ Accept = "application/json" }
        $response = Invoke-RestMethod -Uri "$EurekaUrl/eureka/apps/$ServiceName" -Headers $headers -TimeoutSec 10
        $instances = @($response.application.instance | Where-Object { $null -ne $_ })
        $upInstances = @($instances | Where-Object { $_.status -eq "UP" })
        return [pscustomobject]@{
            Passed = $upInstances.Count -gt 0
            Detail = "up_instances=$($upInstances.Count)"
        }
    } catch {
        return [pscustomobject]@{ Passed = $false; Detail = $_.Exception.Message }
    }
}

function Test-PrometheusTarget {
    try {
        $query = [Uri]::EscapeDataString("up{job=`"$PrometheusJob`"}")
        $response = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query?query=$query" -TimeoutSec 10
        $results = @($response.data.result | Where-Object { $null -ne $_ })
        $upResults = @($results | Where-Object { $_.value[1] -eq "1" })
        return [pscustomobject]@{
            Passed = $upResults.Count -gt 0
            Detail = "up_series=$($upResults.Count)"
        }
    } catch {
        return [pscustomobject]@{ Passed = $false; Detail = $_.Exception.Message }
    }
}

$startedAt = Get-Date
$deadline = $startedAt.AddSeconds($WaitSeconds)

do {
    $api = Test-CustomersApi
    $eureka = Test-EurekaRegistration
    $prometheus = Test-PrometheusTarget
    $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds

    if ($api.Passed -and $eureka.Passed -and $prometheus.Passed) {
        Write-Host "[PASS] Recovery signals ready after ${elapsed}s - API=$($api.Detail), Eureka=$($eureka.Detail), Prometheus=$($prometheus.Detail)" -ForegroundColor Green
        break
    }

    Write-Host "[WAIT] Recovery ${elapsed}s/${WaitSeconds}s - API=$($api.Detail), Eureka=$($eureka.Detail), Prometheus=$($prometheus.Detail)" -ForegroundColor Yellow

    if ((Get-Date) -ge $deadline) {
        Write-Host "[FAIL] Stack did not become ready within ${WaitSeconds}s." -ForegroundColor Red
        exit 1
    }

    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

$verifyScript = Join-Path $PSScriptRoot "verify-stack.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -ApplicationUrl $ApplicationUrl `
    -PrometheusUrl $PrometheusUrl
$verificationExitCode = $LASTEXITCODE

if ($verificationExitCode -ne 0) {
    Write-Host "[FAIL] Recovery signals passed, but full stack verification failed." -ForegroundColor Red
    exit $verificationExitCode
}

Write-Host "[PASS] Recovery and full stack verification succeeded." -ForegroundColor Green
exit 0
