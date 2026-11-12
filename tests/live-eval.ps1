[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:52773',
    [string]$Token = $env:REFERRALPILOT_API_TOKEN,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ApiRoot = "$($BaseUrl.TrimEnd('/'))/api/referralpilot"
$Headers = @{}
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $Headers['X-ReferralPilot-Token'] = $Token
}

function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        $Body = $null
    )
    $params = @{
        Uri = "$ApiRoot$Path"
        Method = $Method
        Headers = $Headers
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    Invoke-RestMethod @params
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$health = Invoke-Api -Path '/health'
Assert-True ($health.demoMode -eq $false) 'Live evaluation requires REFERRALPILOT_DEMO_MODE=false'
Assert-True ($health.agentKeyConfigured -eq $true) 'Live evaluation requires an OpenAI API key'

$null = Invoke-Api -Path '/demo/reset' -Method POST -Body @{}
$referrals = @(Invoke-Api -Path '/referrals')
$targets = @{
    'MSG-CARDIO-001' = @{ Specialty = 'Cardiology'; Urgency = 'SOON'; Statuses = @('pending_review', 'needs_information') }
    'MSG-NEURO-002' = @{ Specialty = 'Neurology'; Urgency = $null; Statuses = @('needs_information') }
    'MSG-CARDIO-003' = @{ Specialty = 'Cardiology'; Urgency = 'URGENT'; Statuses = @('pending_review', 'needs_information') }
}

foreach ($control in $targets.Keys) {
    $referral = $referrals | Where-Object messageControlId -eq $control | Select-Object -First 1
    Assert-True ($null -ne $referral) "Fixture $control is present"
    $null = Invoke-Api -Path "/referrals/$($referral.id)/triage" -Method POST -Body @{}
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 1
    $current = @(Invoke-Api -Path '/referrals')
    $unfinished = $current | Where-Object {
        $_.status -in @('received', 'triage_queued', 'triage_retrying')
    }
} while ($unfinished.Count -gt 0 -and (Get-Date) -lt $deadline)

if ($unfinished.Count -gt 0) {
    throw "Live evaluation timed out with $($unfinished.Count) unfinished referral(s)."
}

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($control in $targets.Keys) {
    $expected = $targets[$control]
    $actual = $current | Where-Object messageControlId -eq $control | Select-Object -First 1
    if ($actual.mode -ne 'live') {
        $failures.Add("$control used mode '$($actual.mode)' instead of live")
    }
    if ($actual.status -notin $expected.Statuses) {
        $failures.Add("$control status was '$($actual.status)', expected one of '$($expected.Statuses -join ', ')'")
    }
    if ($actual.recommendation.specialty -ne $expected.Specialty) {
        $failures.Add("$control specialty was '$($actual.recommendation.specialty)', expected '$($expected.Specialty)'")
    }
    if ($null -ne $expected.Urgency -and $actual.recommendation.urgency -ne $expected.Urgency) {
        $failures.Add("$control urgency was '$($actual.recommendation.urgency)', expected '$($expected.Urgency)'")
    }
    if ($control -eq 'MSG-NEURO-002') {
        $missingText = ($actual.recommendation.missingInformation -join ' ').ToLowerInvariant()
        if (-not $missingText.Contains('imaging')) {
            $failures.Add('MSG-NEURO-002 did not explicitly request the missing imaging report')
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL  $_" -ForegroundColor Red }
    throw "Live model evaluation failed with $($failures.Count) issue(s)."
}

Write-Host 'Live model evaluation passed for all three fixed referral cases.' -ForegroundColor Green
