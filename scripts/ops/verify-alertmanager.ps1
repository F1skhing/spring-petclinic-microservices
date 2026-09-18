[CmdletBinding()]
param(
    [string]$PrometheusUrl = "http://localhost:9091",
    [string]$AlertmanagerUrl = "http://localhost:9093",
    [string]$AlertName = "PetclinicServiceDown",
    [string]$TargetJob = "customers-service",
    [ValidateSet("absent", "present")]
    [string]$ExpectedAlert = "absent",
    [int]$WaitSeconds = 180,
    [int]$PollIntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$lastDetail = "endpoints not checked"

do {
    try {
        $ready = Invoke-WebRequest -UseBasicParsing -Uri "$AlertmanagerUrl/-/ready" -TimeoutSec 10
        $managerResponse = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/alertmanagers" -TimeoutSec 10
        $activeManagers = @($managerResponse.data.activeAlertmanagers)
        $alertResponse = Invoke-WebRequest -UseBasicParsing -Uri "$AlertmanagerUrl/api/v2/alerts" -TimeoutSec 10
        $parsedAlerts = ConvertFrom-Json -InputObject $alertResponse.Content
        $alerts = @($parsedAlerts | Where-Object { $null -ne $_ })
        $matchingAlerts = @(
            $alerts |
                Where-Object {
                    $null -ne $_ -and
                    $_.PSObject.Properties.Name -contains "labels" -and
                    $_.PSObject.Properties.Name -contains "status" -and
                    $_.labels.PSObject.Properties.Name -contains "alertname" -and
                    $_.labels.PSObject.Properties.Name -contains "job" -and
                    $_.status.PSObject.Properties.Name -contains "state" -and
                    $_.labels.alertname -eq $AlertName -and
                    $_.labels.job -eq $TargetJob -and
                    $_.status.state -eq "active"
                }
        )

        $readyPassed = $ready.StatusCode -eq 200
        $connected = $activeManagers.Count -gt 0
        $alertStatePassed = if ($ExpectedAlert -eq "present") {
            $matchingAlerts.Count -gt 0
        } else {
            $matchingAlerts.Count -eq 0
        }
        $lastDetail = "ready=$readyPassed, active_managers=$($activeManagers.Count), matching_alerts=$($matchingAlerts.Count)"

        if ($readyPassed -and $connected -and $alertStatePassed) {
            Write-Host "[PASS] Alertmanager expected_alert=$ExpectedAlert, $lastDetail" -ForegroundColor Green
            exit 0
        }
    } catch {
        $lastDetail = $_.Exception.Message
    }

    if ((Get-Date) -ge $deadline) {
        break
    }
    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

Write-Host "[FAIL] Alertmanager expected_alert=$ExpectedAlert after ${WaitSeconds}s, $lastDetail" -ForegroundColor Red
exit 1
