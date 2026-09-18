[CmdletBinding()]
param(
    [string]$ApplicationUrl = "http://localhost:8080",
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$optionalComposeVariables = @("OPENAI_API_KEY", "AZURE_OPENAI_KEY", "AZURE_OPENAI_ENDPOINT")
foreach ($variableName in $optionalComposeVariables) {
    if (-not (Test-Path "Env:$variableName")) {
        Set-Item -Path "Env:$variableName" -Value "unused-by-mysql-restore"
    }
}

function Invoke-MysqlScalar {
    param([Parameter(Mandatory = $true)][string]$Sql)

    $queryErrorPath = [IO.Path]::GetTempFileName()
    try {
        $queryOutput = @($Sql | docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --batch --skip-column-names' 2> $queryErrorPath)
        $queryExit = $LASTEXITCODE
        $queryErrorLines = @(Get-Content -LiteralPath $queryErrorPath -ErrorAction SilentlyContinue)
        $queryError = (($queryErrorLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    } finally {
        Remove-Item -Force -LiteralPath $queryErrorPath -ErrorAction SilentlyContinue
    }

    if ($queryExit -ne 0) {
        $queryDetail = ((@($queryError) + @($queryOutput) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($queryDetail)) {
            $queryDetail = "No error output was returned."
        }
        throw "MySQL query failed with exit code $queryExit. $queryDetail"
    }

    return (($queryOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$marker = "Restore$timestamp"
$backupPath = Join-Path $projectRoot "backups\mysql\restore-drill-$timestamp.sql"
$backupScript = Join-Path $PSScriptRoot "backup-mysql.ps1"
$waitScript = Join-Path $PSScriptRoot "wait-stack-ready.ps1"

Write-Host "Creating isolated restore marker: $marker"
$createSql = "CREATE TABLE IF NOT EXISTS petclinic.ops_restore_check (id INT NOT NULL PRIMARY KEY, marker VARCHAR(64) NOT NULL); REPLACE INTO petclinic.ops_restore_check (id, marker) VALUES (1, '$marker');"
$null = Invoke-MysqlScalar -Sql $createSql

$beforeBackup = Invoke-MysqlScalar -Sql "SELECT marker FROM petclinic.ops_restore_check WHERE id = 1;"
if ($beforeBackup -ne $marker) {
    throw "The restore marker could not be read before backup."
}
Write-Host "Pre-backup marker read: PASS"

$backupResult = @(& $backupScript -BackupPath $backupPath) | Select-Object -Last 1
if ($null -eq $backupResult -or -not (Test-Path -LiteralPath $backupPath)) {
    throw "The backup script did not produce the expected SQL file."
}

$null = Invoke-MysqlScalar -Sql "DROP TABLE petclinic.ops_restore_check;"
$tableCount = Invoke-MysqlScalar -Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'petclinic' AND table_name = 'ops_restore_check';"
if ($tableCount -ne "0") {
    throw "The restore test table still exists after the controlled deletion."
}
Write-Host "Controlled test-table deletion: PASS"

$servicesStopped = $false
$restartExit = 0
$temporaryName = "restore-$([Guid]::NewGuid().ToString('N')).sql"

try {
    Write-Host "Entering maintenance window: stopping Customers, Visits and Vets..."
    $stopOutput = docker compose stop customers-service visits-service vets-service
    $stopExit = $LASTEXITCODE
    if ($stopOutput) {
        $stopOutput | ForEach-Object { Write-Host $_ }
    }
    if ($stopExit -ne 0) {
        throw "Business service stop failed with exit code $stopExit."
    }
    $servicesStopped = $true

    $copyOutput = docker cp $backupPath "mysql:/tmp/$temporaryName"
    $copyExit = $LASTEXITCODE
    if ($copyOutput) {
        $copyOutput | ForEach-Object { Write-Host $_ }
    }
    if ($copyExit -ne 0) {
        throw "Copying the backup into MySQL failed with exit code $copyExit."
    }

    Write-Host "Restoring the petclinic database from the verified backup..."
    try {
        $restoreErrorPath = [IO.Path]::GetTempFileName()
        try {
            $restoreOutput = @(docker exec -e "RESTORE_FILE=$temporaryName" mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot < "/tmp/$RESTORE_FILE"' 2> $restoreErrorPath)
            $restoreExit = $LASTEXITCODE
            $restoreErrorLines = @(Get-Content -LiteralPath $restoreErrorPath -ErrorAction SilentlyContinue)
            $restoreError = (($restoreErrorLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        } finally {
            Remove-Item -Force -LiteralPath $restoreErrorPath -ErrorAction SilentlyContinue
        }
        if ($restoreOutput) {
            $restoreOutput | ForEach-Object { Write-Host $_ }
        }
        if ($restoreExit -ne 0) {
            throw "MySQL restore failed with exit code $restoreExit. $restoreError"
        }
    } finally {
        docker exec -e "RESTORE_FILE=$temporaryName" mysql sh -c 'rm -f "/tmp/$RESTORE_FILE"' | Out-Null
    }

    $restoredMarker = Invoke-MysqlScalar -Sql "SELECT marker FROM petclinic.ops_restore_check WHERE id = 1;"
    if ($restoredMarker -ne $marker) {
        throw "The restored marker does not match the backup marker."
    }
    Write-Host "Post-restore marker read: PASS (marker=$marker)" -ForegroundColor Green
} finally {
    if ($servicesStopped) {
        Write-Host "Leaving maintenance window: starting business services..."
        $startOutput = docker compose up -d --wait --wait-timeout $TimeoutSeconds customers-service visits-service vets-service
        $restartExit = $LASTEXITCODE
        if ($startOutput) {
            $startOutput | ForEach-Object { Write-Host $_ }
        }
        if ($restartExit -ne 0) {
            Write-Warning "Business service restart failed with exit code $restartExit."
        }
    }
}

if ($restartExit -ne 0) {
    throw "Restore completed, but business services did not restart successfully."
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $waitScript -ApplicationUrl $ApplicationUrl -WaitSeconds $TimeoutSeconds
$stackExit = $LASTEXITCODE
if ($stackExit -ne 0) {
    throw "Restore marker passed, but full stack recovery failed with exit code $stackExit."
}

$null = Invoke-MysqlScalar -Sql "DROP TABLE IF EXISTS petclinic.ops_restore_check;"
$cleanupCount = Invoke-MysqlScalar -Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'petclinic' AND table_name = 'ops_restore_check';"
if ($cleanupCount -ne "0") {
    throw "The restore test table could not be cleaned up."
}
Write-Host "Restore test-table cleanup: PASS"

Write-Host ""
Write-Host "MySQL backup and restore verification passed." -ForegroundColor Green
Write-Host "backup=$backupPath"
Write-Host "sha256=$($backupResult.Sha256)"
Write-Host "marker=$marker"
exit 0
