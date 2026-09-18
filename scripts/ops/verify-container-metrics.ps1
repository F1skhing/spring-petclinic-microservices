[CmdletBinding()]
param(
    [string]$PrometheusUrl = "http://localhost:9091",
    [string]$ApplicationUrl = "http://localhost:8080",
    [int]$WaitSeconds = 180,
    [int]$PollIntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-PrometheusQuery {
    param([Parameter(Mandatory = $true)][string]$Query)

    $encodedQuery = [Uri]::EscapeDataString($Query)
    $response = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/query?query=$encodedQuery" -TimeoutSec 10
    if ($response.status -ne "success") {
        throw "Prometheus query failed: $Query"
    }

    return @($response.data.result | Where-Object { $null -ne $_ })
}

function Test-CadvisorTarget {
    $response = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/targets" -TimeoutSec 10
    $targets = @($response.data.activeTargets | Where-Object { $_.labels.job -eq "cadvisor" })
    $healthy = @($targets | Where-Object { $_.health -eq "up" })
    return [pscustomobject]@{
        Passed = $targets.Count -gt 0 -and $healthy.Count -eq $targets.Count
        Detail = "targets=$($targets.Count), up=$($healthy.Count)"
    }
}

$queries = [ordered]@{
    CPU = 'container_cpu_usage_seconds_total'
    Memory = 'container_memory_working_set_bytes'
    Network = 'container_network_receive_bytes_total'
}

$startedAt = Get-Date
$deadline = $startedAt.AddSeconds($WaitSeconds)
$finalResults = @{}
$ready = $false

while ((Get-Date) -lt $deadline) {
    try {
        $target = Test-CadvisorTarget
        $allMetricsReady = $true
        $details = @("target=$($target.Detail)")

        foreach ($entry in $queries.GetEnumerator()) {
            $results = @(Invoke-PrometheusQuery -Query $entry.Value)
            $finalResults[$entry.Key] = $results
            $details += "$($entry.Key.ToLowerInvariant())_series=$($results.Count)"
            if ($results.Count -eq 0) {
                $allMetricsReady = $false
            }
        }

        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        if ($target.Passed -and $allMetricsReady) {
            Write-Host "[PASS] cAdvisor metrics ready after ${elapsed}s - $($details -join ', ')" -ForegroundColor Green
            $ready = $true
            break
        }

        Write-Host "[WAIT] cAdvisor ${elapsed}s/${WaitSeconds}s - $($details -join ', ')" -ForegroundColor Yellow
    } catch {
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        Write-Host "[WAIT] cAdvisor ${elapsed}s/${WaitSeconds}s - $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}

if (-not $ready) {
    Write-Host "[FAIL] cAdvisor target and metrics did not become ready within ${WaitSeconds}s." -ForegroundColor Red
    exit 1
}

foreach ($entry in $queries.GetEnumerator()) {
    $sample = @($finalResults[$entry.Key] | Select-Object -First 1)[0]
    $nameProperty = $sample.metric.PSObject.Properties["name"]
    $idProperty = $sample.metric.PSObject.Properties["id"]
    if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
        $containerName = [string]$nameProperty.Value
    } elseif ($null -ne $idProperty -and -not [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
        $containerName = [string]$idProperty.Value
    } else {
        $containerName = "labels=$($sample.metric.PSObject.Properties.Name -join ',')"
    }
    Write-Host "[PASS] $($entry.Key) metric - query='$($entry.Value)', sample_container='$containerName', value=$($sample.value[1])" -ForegroundColor Green
}

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify-stack.ps1") `
    -ApplicationUrl $ApplicationUrl `
    -PrometheusUrl $PrometheusUrl
$stackExit = $LASTEXITCODE
if ($stackExit -ne 0) {
    Write-Host "[FAIL] Container metrics passed, but full stack verification failed." -ForegroundColor Red
    exit $stackExit
}

Write-Host "[PASS] Container resource metrics and full stack verification succeeded." -ForegroundColor Green
exit 0
