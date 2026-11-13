[CmdletBinding()]
param(
    [string]$Image = $env:REFERRALPILOT_IMAGE,
    [string]$Token = $env:REFERRALPILOT_API_TOKEN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Image)) {
    $Image = 'iris-community:2027.1.0AI.109.0'
}

Push-Location $root
try {
    Write-Host '1/4 Static validation' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'validate.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Static validation failed.'
    }

    & docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "AI Hub image '$Image' is not loaded. Import and retag the approved EAP image first."
    }

    Write-Host '2/4 Docker build and startup' -ForegroundColor Cyan
    $env:REFERRALPILOT_IMAGE = $Image
    & docker compose up --build -d
    if ($LASTEXITCODE -ne 0) {
        throw 'docker compose up failed.'
    }
    $health = $null
    $deadline = (Get-Date).AddSeconds(180)
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('_SYSTEM:SYS'))
    $healthHeaders = @{ Authorization = "Basic $basic" }
    do {
        try {
            $health = Invoke-RestMethod -Uri 'http://localhost:52773/api/referralpilot/health' -Headers $healthHeaders -TimeoutSec 5
            if ($health.ready -eq 1) { break }
        } catch {
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $health -or $health.ready -ne 1) {
        & docker compose logs --no-color --tail 200 iris
        throw 'IRIS did not become ready within 180 seconds.'
    }

    Write-Host '3/4 ObjectScript unit tests' -ForegroundColor Cyan
    $testCommand = '##class(%UnitTest.Manager).RunTest("ReferralPilot.Tests")'
    $unitOutput = & docker compose exec -T iris iris session IRISAPP $testCommand 2>&1
    $unitOutput | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'The IRIS unit-test command exited with an error.'
    }
    $failed = $unitOutput | Select-String -Pattern '(?i)Tests failed:\s*[1-9]|Test failed:' -Quiet
    if ($failed) {
        throw 'One or more IRIS unit tests failed; inspect the output above.'
    }

    Write-Host '4/4 End-to-end HTTP smoke test' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'smoke.ps1') -Token $Token
    if ($LASTEXITCODE -ne 0) {
        throw 'End-to-end smoke test failed.'
    }

    Write-Host 'All available acceptance gates passed.' -ForegroundColor Green
} finally {
    Pop-Location
}
