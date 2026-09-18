[CmdletBinding()]
param(
    [string]$ApplicationUrl = "http://localhost:8080",
    [int]$TimeoutSeconds = 300,
    [int]$PollIntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-MysqlContainer {
    $inspectJson = docker inspect mysql 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ConvertFrom-Json -InputObject ($inspectJson -join [Environment]::NewLine)
}

function Get-MysqlHealth {
    $container = Get-MysqlContainer
    if ($null -eq $container) {
        return "missing"
    }

    if ($null -ne $container.State.Health) {
        return [string]$container.State.Health.Status
    }

    return [string]$container.State.Status
}

function Wait-MysqlHealthy {
    param([datetime]$Deadline)

    while ((Get-Date) -lt $Deadline) {
        $health = Get-MysqlHealth
        Write-Host "MySQL health: $health"
        if ($health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "MySQL did not become healthy within $TimeoutSeconds seconds."
}

$mysqlContainer = Get-MysqlContainer
if ($null -eq $mysqlContainer) {
    throw "The MySQL container could not be inspected."
}

$mysqlMount = @($mysqlContainer.Mounts | Where-Object {
    $_.Destination -eq "/var/lib/mysql" -and $_.Type -eq "volume"
}) | Select-Object -First 1

if ($null -eq $mysqlMount -or [string]::IsNullOrWhiteSpace([string]$mysqlMount.Name)) {
    throw "MySQL does not have a named volume mounted at /var/lib/mysql."
}
$volumeName = [string]$mysqlMount.Name
Write-Host "Named volume: $volumeName"

$marker = "Persist$((Get-Date).ToString('HHmmss'))"
$payload = @{
    firstName = "Storage"
    lastName = $marker
    address = "MySQL named volume check"
    city = "OpsLab"
    telephone = "900$((Get-Date).ToString('HHmmss'))"
}

$created = Invoke-RestMethod `
    -Method Post `
    -Uri "$ApplicationUrl/api/customer/owners" `
    -ContentType "application/json" `
    -Body ($payload | ConvertTo-Json) `
    -TimeoutSec 15

$ownerId = [int]$created.id
if ($ownerId -le 0) {
    throw "The Customers API did not return a valid owner ID."
}
Write-Host "Created persistence marker: owner_id=$ownerId, last_name=$marker"

$before = Invoke-RestMethod -Uri "$ApplicationUrl/api/customer/owners/$ownerId" -TimeoutSec 15
if ($before.id -ne $ownerId -or $before.lastName -ne $marker) {
    throw "The marker could not be read before recreating MySQL."
}
Write-Host "Pre-recreate read: PASS"

Write-Host "Recreating only the MySQL container; the named volume is preserved..."
docker compose up -d --force-recreate mysql
$recreateExit = $LASTEXITCODE
if ($recreateExit -ne 0) {
    throw "MySQL recreation failed with exit code $recreateExit."
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
Wait-MysqlHealthy -Deadline $deadline

$recovered = $null
while ((Get-Date) -lt $deadline) {
    try {
        $candidate = Invoke-RestMethod -Uri "$ApplicationUrl/api/customer/owners/$ownerId" -TimeoutSec 10
        if ($candidate.id -eq $ownerId -and $candidate.lastName -eq $marker) {
            $recovered = $candidate
            break
        }
    } catch {
        Write-Host "Customers API is recovering: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}

if ($null -eq $recovered) {
    throw "The persistence marker was not readable after MySQL recreation."
}
Write-Host "Post-recreate read: PASS (owner_id=$ownerId, last_name=$marker)"

& "$PSScriptRoot\verify-stack.ps1" -ApplicationUrl $ApplicationUrl
$stackExit = $LASTEXITCODE
if ($stackExit -ne 0) {
    throw "Persistence passed, but full stack verification failed with exit code $stackExit."
}

Write-Host ""
Write-Host "MySQL persistence verification passed." -ForegroundColor Green
Write-Host "volume=$volumeName owner_id=$ownerId marker=$marker"
exit 0
