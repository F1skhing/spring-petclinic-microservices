[CmdletBinding()]
param(
    [string]$PrometheusUrl = "http://localhost:9091",
    [string]$AlertName = "PetclinicServiceDown",
    [string]$TargetJob = "customers-service",
    [ValidateSet("inactive", "pending", "firing")]
    [string]$ExpectedState = "inactive",
    [int]$WaitSeconds = 180,
    [int]$PollIntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$lastDetail = "rule not checked"

do {
    try {
        $response = Invoke-RestMethod -Uri "$PrometheusUrl/api/v1/rules?type=alert" -TimeoutSec 10
        $rules = @(
            $response.data.groups |
                ForEach-Object { $_.rules } |
                Where-Object { $_.name -eq $AlertName }
        )

        if ($rules.Count -eq 0) {
            $lastDetail = "rule not loaded"
        } else {
            $rule = $rules[0]

            if ($rule.health -eq "err") {
                Write-Host "[FAIL] Alert rule '$AlertName' health=err." -ForegroundColor Red
                exit 1
            }

            if ($ExpectedState -eq "inactive") {
                $passed = $rule.health -eq "ok" -and $rule.state -eq "inactive"
                $lastDetail = "rule_state=$($rule.state), health=$($rule.health)"
            } else {
                $alerts = if ($rule.PSObject.Properties.Name -contains "alerts") {
                    @($rule.alerts)
                } else {
                    @()
                }
                $matchingAlerts = @(
                    $alerts |
                        Where-Object {
                            $_.labels.job -eq $TargetJob -and $_.state -eq $ExpectedState
                        }
                )
                $passed = $rule.health -eq "ok" -and $matchingAlerts.Count -gt 0
                $lastDetail = "rule_state=$($rule.state), health=$($rule.health), target_job=$TargetJob, matching_alerts=$($matchingAlerts.Count)"
            }

            if ($passed) {
                Write-Host "[PASS] $AlertName expected=$ExpectedState, $lastDetail" -ForegroundColor Green
                exit 0
            }
        }
    } catch {
        $lastDetail = $_.Exception.Message
    }

    if ((Get-Date) -ge $deadline) {
        break
    }
    Start-Sleep -Seconds $PollIntervalSeconds
} while ($true)

Write-Host "[FAIL] $AlertName expected=$ExpectedState after ${WaitSeconds}s, $lastDetail" -ForegroundColor Red
exit 1
