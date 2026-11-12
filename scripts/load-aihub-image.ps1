[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImageArchive,
    [string]$ShortTag = 'iris-community:2027.1.0AI.109.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$archivePath = if ([System.IO.Path]::IsPathRooted($ImageArchive)) {
    $ImageArchive
} else {
    Join-Path $root $ImageArchive
}
if (-not (Test-Path -LiteralPath $archivePath)) {
    throw "Image archive not found: $archivePath"
}

Write-Host "Loading $archivePath ..." -ForegroundColor Cyan
$output = & docker image load -i $archivePath 2>&1
$output | Write-Host
if ($LASTEXITCODE -ne 0) {
    throw 'docker image load failed.'
}

$loadedTag = $output |
    ForEach-Object { [string]$_ } |
    ForEach-Object {
        if ($_ -match '^Loaded image:\s+(.+)$') { $Matches[1].Trim() }
    } |
    Select-Object -Last 1

$shortExists = $true
& docker image inspect $ShortTag *> $null
if ($LASTEXITCODE -ne 0) {
    $shortExists = $false
}

if (-not $shortExists) {
    if ([string]::IsNullOrWhiteSpace($loadedTag)) {
        throw "The image loaded, but its source tag could not be identified. Run 'docker images' and retag it as $ShortTag."
    }
    Write-Host "Tagging $loadedTag -> $ShortTag" -ForegroundColor Cyan
    & docker tag $loadedTag $ShortTag
    if ($LASTEXITCODE -ne 0) {
        throw "docker tag failed. Retag the loaded image as $ShortTag manually."
    }
}

& docker image inspect $ShortTag *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Expected image tag is still unavailable: $ShortTag"
}

Write-Host "AI Hub image is ready: $ShortTag" -ForegroundColor Green
