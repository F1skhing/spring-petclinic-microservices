param(
    [int]$TimeoutSeconds = 180,
    [int]$PollIntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'
$grafanaBase = 'http://localhost:3030'
$prometheusBase = 'http://localhost:9091'
$dashboardUid = 'petclinic-container-resources'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

function Invoke-PrometheusQuery {
    param([string]$Query)

    $uri = "$prometheusBase/api/v1/query?query=$([uri]::EscapeDataString($Query))"
    $response = Invoke-RestMethod -Uri $uri -TimeoutSec 15
    if ($response.status -ne 'success') {
        throw "Prometheus query failed: $Query"
    }

    return @($response.data.result)
}

do {
    try {
        $dashboard = Invoke-RestMethod -Uri "$grafanaBase/api/dashboards/uid/$dashboardUid" -TimeoutSec 15
        if ($dashboard.dashboard.uid -eq $dashboardUid) {
            break
        }
    }
    catch {
        $remaining = [math]::Max(0, [int](($deadline - (Get-Date)).TotalSeconds))
        Write-Host "[WAIT] Grafana dashboard is not ready; remaining=$($remaining)s" -ForegroundColor Yellow
    }

    if ((Get-Date) -ge $deadline) {
        throw "Grafana dashboard '$dashboardUid' was not provisioned within $TimeoutSeconds seconds."
    }

    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

$expectedPanels = @(
    'Container CPU Usage',
    'Container Memory Working Set',
    'Container Network Receive',
    'Container Network Transmit'
)

$panelTitles = @($dashboard.dashboard.panels | ForEach-Object { $_.title })
foreach ($title in $expectedPanels) {
    if ($panelTitles -notcontains $title) {
        throw "Grafana dashboard is missing panel: $title"
    }
}
Write-Host "[PASS] Grafana provisioned dashboard uid=$dashboardUid, panels=$($expectedPanels.Count)" -ForegroundColor Green

$queries = [ordered]@{
    CPU = 'sum by (name) (rate(container_cpu_usage_seconds_total{name!="",cpu="total"}[5m])) * 100'
    Memory = 'max by (name) (container_memory_working_set_bytes{name!=""})'
    NetworkReceive = 'sum by (name) (rate(container_network_receive_bytes_total{name!=""}[5m]))'
    NetworkTransmit = 'sum by (name) (rate(container_network_transmit_bytes_total{name!=""}[5m]))'
}

foreach ($entry in $queries.GetEnumerator()) {
    $results = @(Invoke-PrometheusQuery -Query $entry.Value)
    $names = @(
        $results |
            Where-Object { $_.metric.PSObject.Properties.Name -contains 'name' -and $_.metric.name } |
            ForEach-Object { $_.metric.name } |
            Sort-Object -Unique
    )

    if ($names.Count -lt 2) {
        throw "$($entry.Key) query returned fewer than two named containers."
    }

    Write-Host "[PASS] $($entry.Key) query - series=$($results.Count), containers=$($names.Count), sample=$($names[0])" -ForegroundColor Green
}

& "$PSScriptRoot\verify-stack.ps1"
$stackExit = $LASTEXITCODE
if ($stackExit -ne 0) {
    throw "Full stack verification failed with exit code $stackExit."
}

Write-Host ''
Write-Host '[PASS] Grafana container dashboard and full stack verification succeeded.' -ForegroundColor Green
exit 0
