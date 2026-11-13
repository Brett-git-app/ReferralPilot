[CmdletBinding()]
param(
    [string]$OutputDirectory = 'dist'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

Push-Location $root
try {
    & (Join-Path $PSScriptRoot 'validate.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Package creation blocked by static validation failures.'
    }

    [xml]$module = Get-Content -Raw -LiteralPath (Join-Path $root 'module.xml')
    $version = [string]$module.Export.Document.Module.Version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'module.xml does not declare a package version.'
    }

    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
        $OutputDirectory
    } else {
        Join-Path $root $OutputDirectory
    }
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    $archive = Join-Path $outputPath "referralpilot-$version.tgz"

    & tar -czf $archive --exclude='.git' --exclude='.env' --exclude='dist' --exclude='*.log' -C $root .
    if ($LASTEXITCODE -ne 0) {
        throw 'tar failed to create the package.'
    }
    $entries = & tar -tzf $archive
    if ($entries -contains './.env') {
        throw 'Package unexpectedly contains a local .env file.'
    }

    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $length = (Get-Item -LiteralPath $archive).Length
    $manifest = [ordered]@{
        package = 'ReferralPilot'
        version = $version
        archive = [System.IO.Path]::GetFileName($archive)
        bytes = $length
        sha256 = $hash
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $manifestPath = Join-Path $outputPath "referralpilot-$version.manifest.json"
    $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8

    Write-Host "Package created: $archive" -ForegroundColor Green
    Write-Host "SHA-256: $hash"
    Write-Host "Manifest: $manifestPath"
} finally {
    Pop-Location
}
