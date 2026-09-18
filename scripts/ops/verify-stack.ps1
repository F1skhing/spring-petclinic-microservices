[CmdletBinding()]
param(
    [string]$ApplicationUrl = "http://localhost:8080",
    [string]$PrometheusUrl = "http://localhost:9091",
    [int[]]$BlockedHostPorts = @(8081, 8082, 8083)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:FailureCount = 0

function Write-CheckResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $status = if ($Passed) { "PASS" } else { "FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    Write-Host ("[{0}] {1} - {2}" -f $status, $Name, $Detail) -ForegroundColor $color

    if (-not $Passed) {
        $script:FailureCount++
    }
}

function Get-ResponseText {
    param($Content)

    if ($Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($Content).Trim()
    }

    return ([string]$Content).Trim()
}

try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$ApplicationUrl/nginx-health" -TimeoutSec 10
    $body = Get-ResponseText $response.Content
    $passed = $response.StatusCode -eq 200 -and $body -eq "nginx ok"
    Write-CheckResult "Nginx health" $passed "HTTP $($response.StatusCode), body='$body'"
} catch {
    Write-CheckResult "Nginx health" $false $_.Exception.Message
}

try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $ApplicationUrl -TimeoutSec 10
    $passed = $response.StatusCode -eq 200
    Write-CheckResult "Application entry" $passed "HTTP $($response.StatusCode), bytes=$($response.RawContentLength)"
} catch {
    Write-CheckResult "Application entry" $false $_.Exception.Message
}

try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$ApplicationUrl/api/customer/owners" -TimeoutSec 10
    $body = Get-ResponseText $response.Content
    $null = ConvertFrom-Json -InputObject $body -ErrorAction Stop
    $passed = $response.StatusCode -eq 200
    Write-CheckResult "Customers API" $passed "HTTP $($response.StatusCode), valid JSON, bytes=$($response.RawContentLength)"
} catch {
    Write-CheckResult "Customers API" $false $_.Exception.Message
}

foreach ($port in $BlockedHostPorts) {
    $reachable = Test-NetConnection -ComputerName localhost -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
    Write-CheckResult "Host port $port blocked" (-not $reachable) "reachable=$reachable"
}

$expectedJobs = @("customers-service", "visits-service", "vets-service")

try {
    $targetResponse = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/targets" -TimeoutSec 10

    foreach ($job in $expectedJobs) {
        $targets = @($targetResponse.data.activeTargets | Where-Object { $_.labels.job -eq $job })
        $unhealthy = @($targets | Where-Object { $_.health -ne "up" })
        $passed = $targets.Count -gt 0 -and $unhealthy.Count -eq 0
        $detail = if ($targets.Count -eq 0) {
            "target missing"
        } else {
            "targets=$($targets.Count), health=$((($targets | ForEach-Object { $_.health }) -join ','))"
        }
        Write-CheckResult "Prometheus $job" $passed $detail
    }
} catch {
    foreach ($job in $expectedJobs) {
        Write-CheckResult "Prometheus $job" $false $_.Exception.Message
    }
}

Write-Host ""
if ($script:FailureCount -gt 0) {
    Write-Host "Stack verification failed: $script:FailureCount check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "Stack verification passed: all checks succeeded." -ForegroundColor Green
exit 0
