[CmdletBinding()]
param(
    [string]$BackupPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupPath = Join-Path $projectRoot "backups\mysql\petclinic-$timestamp.sql"
} elseif (-not [IO.Path]::IsPathRooted($BackupPath)) {
    $BackupPath = Join-Path $projectRoot $BackupPath
}

$BackupPath = [IO.Path]::GetFullPath($BackupPath)
$backupDirectory = Split-Path -Parent $BackupPath
New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null

if (Test-Path -LiteralPath $BackupPath) {
    throw "Backup already exists: $BackupPath"
}

$inspectJson = docker inspect mysql 2>$null
$inspectExit = $LASTEXITCODE
if ($inspectExit -ne 0) {
    throw "The MySQL container could not be inspected."
}

$mysqlContainer = ConvertFrom-Json -InputObject ($inspectJson -join [Environment]::NewLine)
$healthProperty = $mysqlContainer.State.PSObject.Properties["Health"]
$mysqlHealth = if ($null -ne $healthProperty) {
    [string]$mysqlContainer.State.Health.Status
} else {
    [string]$mysqlContainer.State.Status
}

if ($mysqlHealth -ne "healthy") {
    throw "MySQL must be healthy before backup; current status is '$mysqlHealth'."
}

$temporaryName = "petclinic-$([Guid]::NewGuid().ToString('N')).sql"
Write-Host "Creating logical backup inside the MySQL container..."

$dumpErrorPath = [IO.Path]::GetTempFileName()
try {
    $dumpOutput = @(docker exec -e "BACKUP_FILE=$temporaryName" mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --triggers --events --hex-blob --set-gtid-purged=OFF --add-drop-database --databases petclinic > "/tmp/$BACKUP_FILE"' 2> $dumpErrorPath)
    $dumpExit = $LASTEXITCODE
    $dumpErrorLines = @(Get-Content -LiteralPath $dumpErrorPath -ErrorAction SilentlyContinue)
    $dumpError = (($dumpErrorLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
} finally {
    Remove-Item -Force -LiteralPath $dumpErrorPath -ErrorAction SilentlyContinue
}
if ($dumpOutput) {
    $dumpOutput | ForEach-Object { Write-Host $_ }
}
if ($dumpExit -ne 0) {
    throw "mysqldump failed with exit code $dumpExit. $dumpError"
}

try {
    $copyOutput = docker cp "mysql:/tmp/$temporaryName" $BackupPath
    $copyExit = $LASTEXITCODE
    if ($copyOutput) {
        $copyOutput | ForEach-Object { Write-Host $_ }
    }
    if ($copyExit -ne 0) {
        throw "docker cp failed with exit code $copyExit."
    }
} finally {
    docker exec -e "BACKUP_FILE=$temporaryName" mysql sh -c 'rm -f "/tmp/$BACKUP_FILE"' | Out-Null
}

$backupFile = Get-Item -LiteralPath $BackupPath
if ($backupFile.Length -lt 1024) {
    throw "Backup file is unexpectedly small: $($backupFile.Length) bytes."
}

$useStatement = Select-String -LiteralPath $BackupPath -SimpleMatch 'USE `petclinic`;' -Quiet
$ownersTable = Select-String -LiteralPath $BackupPath -SimpleMatch 'CREATE TABLE `owners`' -Quiet
if (-not $useStatement -or -not $ownersTable) {
    throw "Backup does not contain the expected petclinic database markers."
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $BackupPath).Hash.ToLowerInvariant()
$hashPath = "$BackupPath.sha256"
$hashLine = "$hash  $($backupFile.Name)"
[IO.File]::WriteAllText($hashPath, "$hashLine$([Environment]::NewLine)", (New-Object Text.UTF8Encoding($false)))

Write-Host "Backup validation: PASS" -ForegroundColor Green
Write-Host "Backup path: $BackupPath"
Write-Host "Backup bytes: $($backupFile.Length)"
Write-Host "SHA-256: $hash"

return [pscustomobject]@{
    Path = $BackupPath
    HashPath = $hashPath
    Bytes = $backupFile.Length
    Sha256 = $hash
}
