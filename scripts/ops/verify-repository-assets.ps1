[CmdletBinding()]
param(
    [string[]]$MarkdownFiles = @(
        "README.md",
        "docs/operations/README.md"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$failureCount = 0

Push-Location $repositoryRoot
try {
    Write-Host "[CHECK] PowerShell syntax"
    $powerShellFiles = @(Get-ChildItem -Path "scripts/ops" -Filter "*.ps1" -File | Sort-Object FullName)
    if ($powerShellFiles.Count -eq 0) {
        throw "No PowerShell scripts were found under scripts/ops."
    }

    foreach ($file in $powerShellFiles) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        if ($parseErrors.Count -eq 0) {
            Write-Host "[PASS] PowerShell syntax - $($file.FullName.Substring($repositoryRoot.Length + 1))" -ForegroundColor Green
            continue
        }

        $failureCount++
        Write-Host "[FAIL] PowerShell syntax - $($file.FullName.Substring($repositoryRoot.Length + 1))" -ForegroundColor Red
        foreach ($parseError in $parseErrors) {
            Write-Host (
                "       line {0}, column {1}: {2}" -f `
                    $parseError.Extent.StartLineNumber,
                    $parseError.Extent.StartColumnNumber,
                    $parseError.Message
            ) -ForegroundColor Red
        }
    }

    Write-Host "[CHECK] Local Markdown links"
    $linkPattern = [regex]'!?\[[^\]]*\]\((?<target>[^)]+)\)'

    foreach ($markdownPath in $MarkdownFiles) {
        $fullMarkdownPath = Join-Path $repositoryRoot $markdownPath
        if (-not (Test-Path -LiteralPath $fullMarkdownPath -PathType Leaf)) {
            $failureCount++
            Write-Host "[FAIL] Markdown file is missing - $markdownPath" -ForegroundColor Red
            continue
        }

        $content = Get-Content -LiteralPath $fullMarkdownPath -Raw -Encoding UTF8
        $brokenLinks = @()

        foreach ($match in $linkPattern.Matches($content)) {
            $target = $match.Groups["target"].Value.Trim().Trim('<', '>')
            if ([string]::IsNullOrWhiteSpace($target) -or
                $target.StartsWith("#") -or
                $target -match '^(?i:https?|mailto):') {
                continue
            }

            $localTarget = ($target -split '#', 2)[0]
            $localTarget = ($localTarget -split '\?', 2)[0]
            if ([string]::IsNullOrWhiteSpace($localTarget)) {
                continue
            }

            $localTarget = [Uri]::UnescapeDataString($localTarget)
            if ($localTarget.StartsWith("/")) {
                $candidatePath = Join-Path $repositoryRoot $localTarget.TrimStart('/')
            }
            else {
                $candidatePath = Join-Path (Split-Path $fullMarkdownPath -Parent) $localTarget
            }

            if (-not (Test-Path -LiteralPath $candidatePath)) {
                $brokenLinks += $target
            }
        }

        if ($brokenLinks.Count -eq 0) {
            Write-Host "[PASS] Local Markdown links - $markdownPath" -ForegroundColor Green
            continue
        }

        $failureCount += $brokenLinks.Count
        foreach ($brokenLink in $brokenLinks) {
            Write-Host "[FAIL] Broken local link - $markdownPath -> $brokenLink" -ForegroundColor Red
        }
    }
}
finally {
    Pop-Location
}

if ($failureCount -gt 0) {
    throw "Repository asset verification failed with $failureCount error(s)."
}

Write-Host "Repository PowerShell syntax and Markdown link checks passed." -ForegroundColor Green
