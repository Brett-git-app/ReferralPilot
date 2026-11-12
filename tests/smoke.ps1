[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:52773',
    [string]$Token = $env:REFERRALPILOT_API_TOKEN,
    [int]$StartupTimeoutSeconds = 180
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
        $Body = $null,
        [switch]$RawText
    )

    $params = @{
        Uri = "$ApiRoot$Path"
        Method = $Method
        Headers = $Headers
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        if ($RawText) {
            $params.ContentType = 'text/plain'
            $params.Body = [string]$Body
        } else {
            $params.ContentType = 'application/json'
            $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }
    }
    Invoke-RestMethod @params
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Wait-For {
    param(
        [Parameter(Mandatory)][scriptblock]$Probe,
        [Parameter(Mandatory)][string]$Description,
        [int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $value = & $Probe
            if ($null -ne $value) {
                return $value
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for $Description. Last error: $lastError"
}

Write-Host 'Waiting for ReferralPilot health endpoint...'
$health = Wait-For -Description 'ReferralPilot readiness' -TimeoutSeconds $StartupTimeoutSeconds -Probe {
    $result = Invoke-Api -Path '/health'
    if ($result.ready -eq 1) { return $result }
}
Assert-True ($health.application -eq 'ReferralPilot') 'health endpoint identifies ReferralPilot'
if ($health.knowledgeBase -ne 'ready') {
    Write-Warning "Knowledge base is $($health.knowledgeBase); deterministic policy fallback will be used."
}
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $unauthorizedStatus = $null
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$ApiRoot/referrals" -TimeoutSec 15 | Out-Null
    } catch {
        $unauthorizedStatus = $_.Exception.Response.StatusCode.value__
    }
    Assert-True ($unauthorizedStatus -eq 401) 'API token protection rejects unauthenticated requests'
}

Write-Host 'Resetting synthetic demo data...'
$reset = Invoke-Api -Path '/demo/reset' -Method POST -Body @{}
Assert-True ($reset.loaded -eq 3) 'demo reset loads exactly three referrals'

$referrals = @(Invoke-Api -Path '/referrals')
Assert-True ($referrals.Count -eq 3) 'referral list contains three records'
$referral = $referrals |
    Where-Object { $_.status -eq 'received' -and $_.messageControlId -eq 'MSG-CARDIO-001' } |
    Select-Object -First 1
Assert-True ($null -ne $referral) 'one demo referral is ready for triage'

Write-Host "Starting triage for $($referral.id)..."
$queued = Invoke-Api -Path "/referrals/$($referral.id)/triage" -Method POST -Body @{}
Assert-True ($queued.status -eq 'queued') 'triage request is accepted'

$triage = Wait-For -Description 'triage completion' -TimeoutSeconds 60 -Probe {
    $current = Invoke-Api -Path "/referrals/$($referral.id)"
    if ($current.status -in @('pending_review', 'needs_information', 'manual_triage_required')) {
        return $current
    }
}

if ($triage.status -eq 'manual_triage_required') {
    Write-Warning 'Automated triage exhausted retries; exercising the human fallback path.'
    $triage = Invoke-Api -Path "/referrals/$($referral.id)/manual-triage" -Method POST -Body @{
        specialty = 'Cardiology'
        urgency = 'SOON'
        missingInformation = @()
        rationale = 'End-to-end validation completed by a human reviewer.'
        reviewer = 'Validation Reviewer'
    }
}

Assert-True ([bool]$triage.recommendation.specialty) 'a recommendation was recorded'
Assert-True ($triage.recommendation.reviewRequired -eq 1) 'recommendation still requires human review'

Write-Host 'Approving recommendation...'
$approved = Invoke-Api -Path "/referrals/$($referral.id)/approve" -Method POST -Body @{
    reviewer = 'Validation Reviewer'
    comment = 'Approved by automated end-to-end validation.'
}
Assert-True ($approved.status -eq 'approved') 'reviewer approval transitions the referral to approved'

$outbound = Wait-For -Description 'downstream HL7 routing' -TimeoutSeconds 30 -Probe {
    try {
        $message = Invoke-Api -Path "/referrals/$($referral.id)/outbound"
        if ($message.message) { return $message }
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
    }
}
Assert-True ($outbound.message -match '^MSH\|') 'outbound payload is an HL7 message'
Assert-True ($outbound.message -match "OUT-$([regex]::Escape($referral.id))") 'outbound MSH-10 identifies the referral'

$guardStatus = $null
try {
    Invoke-Api -Path "/referrals/$($referral.id)/triage" -Method POST -Body @{} | Out-Null
} catch {
    $guardStatus = $_.Exception.Response.StatusCode.value__
}
Assert-True ($guardStatus -eq 409) 'approved referral cannot be triaged again'

$fixturePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'data/referral-cardio.hl7'
$fixture = Get-Content -Raw -LiteralPath $fixturePath
$duplicate = Invoke-Api -Path '/hl7' -Method POST -RawText -Body $fixture
Assert-True ($duplicate.id -eq $referral.id) 'duplicate MSH-10 is idempotent'
Assert-True ($duplicate.status -eq 'approved') 'duplicate intake does not mutate the approved workflow'

$pipeline = Invoke-Api -Path '/pipeline'
Assert-True ($pipeline.total -eq 3) 'pipeline still contains three unique referrals'

Write-Host "Smoke test passed. Referral $($referral.id) completed triage, approval, routing, state guards, and duplicate intake." -ForegroundColor Green
