[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
}

function Add-Warning([string]$Message) {
    $script:warnings.Add($Message)
}

function Require-File([string]$RelativePath) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $RelativePath))) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

@(
    'Dockerfile',
    'docker-compose.yml',
    'iris.script',
    'module.xml',
    'src/ReferralPilot/API.cls',
    'src/ReferralPilot/Store.cls',
    'src/ReferralPilot/Tests/Store.cls',
    'src/ReferralPilot/Tests/Pipeline.cls',
    'src/ReferralPilot/Tests/Routing.cls',
    'data/referral-cardio.hl7',
    'data/referral-neuro.hl7',
    'data/referral-urgent.hl7'
) | ForEach-Object { Require-File $_ }

try {
    [xml]$module = Get-Content -Raw -LiteralPath (Join-Path $root 'module.xml')
    $moduleNode = $module.Export.Document.Module
    if ($moduleNode.Name -ne 'ReferralPilot') {
        Add-Failure 'module.xml must define the ReferralPilot module'
    }
    if ([string]::IsNullOrWhiteSpace($moduleNode.Version)) {
        Add-Failure 'module.xml must declare a version'
    }
    if ($null -eq $moduleNode.SystemRequirements) {
        Add-Failure 'module.xml must declare IRIS interoperability system requirements'
    } else {
        if ($moduleNode.SystemRequirements.Interoperability -ne 'enabled') {
            Add-Failure 'module.xml must require Interoperability= enabled'
        }
        if ($moduleNode.SystemRequirements.Version -notmatch '2026\.3') {
            Add-Failure 'module.xml must require IRIS 2026.3 or later'
        }
    }
    $dependencyNames = @($moduleNode.Dependencies.Module | ForEach-Object { $_.Name })
    if ($dependencyNames -notcontains 'iris-llm') {
        Add-Failure 'module.xml must declare the iris-llm dependency'
    }
} catch {
    Add-Failure "module.xml is not valid XML: $($_.Exception.Message)"
}

$sourceFiles = Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Filter '*.cls' -File
foreach ($file in $sourceFiles) {
    $source = Get-Content -Raw -LiteralPath $file.FullName
    if ($source -match '"demoMode":demoMode') {
        Add-Failure "Unparenthesized Dynamic Object property in $($file.FullName)"
    }
    if ($source -match '"clinicNote":\$Select') {
        Add-Failure "Unparenthesized `$Select expression in $($file.FullName)"
    }
}

$store = Get-Content -Raw -LiteralPath (Join-Path $root 'src/ReferralPilot/Store.cls')
foreach ($marker in @(
    'ClassMethod CanStartTriage',
    'ClassMethod ClaimTriage',
    'ClassMethod ReleaseTriageClaim',
    'ClassMethod IsApprovedSpecialty',
    'ClassMethod ValidateReviewer',
    'ClassMethod Outbound',
    'Triage is closed for referral status'
)) {
    if (-not $store.Contains($marker)) {
        Add-Failure "Store.cls is missing required guard: $marker"
    }
}

$api = Get-Content -Raw -LiteralPath (Join-Path $root 'src/ReferralPilot/API.cls')
foreach ($marker in @('OnPreDispatch', 'ReadJsonBody', 'OutboundById', 'CanStartTriage', '1048576')) {
    if (-not $api.Contains($marker)) {
        Add-Failure "API.cls is missing required control: $marker"
    }
}
$routeMatch = [regex]::Match($api, '(?s)<Routes>(.*?)</Routes>')
if (-not $routeMatch.Success) {
    Add-Failure 'API.cls does not contain a complete REST route map'
} else {
    try {
        [xml]$routes = "<Routes>$($routeMatch.Groups[1].Value)</Routes>"
        if (@($routes.Routes.Route).Count -lt 15) {
            Add-Failure 'API route map is unexpectedly incomplete'
        }
    } catch {
        Add-Failure "API route map is not valid XML: $($_.Exception.Message)"
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) {
    Add-Warning 'Node.js is not available; dashboard JavaScript syntax was not checked'
} else {
    $uiLines = Get-Content -LiteralPath (Join-Path $root 'src/ReferralPilot/UI.cls')
    $scriptLines = [System.Collections.Generic.List[string]]::new()
    $insideScript = $false
    foreach ($line in $uiLines) {
        if ($line -match 'page_"?<script>"?_\$C\(10\)') {
            $insideScript = $true
            continue
        }
        if ($insideScript -and $line -match 'page_"?</script></body></html>"?_\$C\(10\)') {
            break
        }
        if ($insideScript -and $line -match '^\s*Set page=page_"(.*)"_\$C\(10\)\s*$') {
            $scriptLines.Add($Matches[1].Replace('""', '"'))
        }
    }
    if ($scriptLines.Count -eq 0) {
        Add-Failure 'Could not extract dashboard JavaScript from UI.cls'
    } else {
        $tempJs = Join-Path ([System.IO.Path]::GetTempPath()) "referralpilot-ui-$PID.js"
        try {
            [System.IO.File]::WriteAllText($tempJs, ($scriptLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
            $nodeOutput = & node --check $tempJs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Add-Failure "Dashboard JavaScript syntax error: $nodeOutput"
            }
        } finally {
            if (Test-Path -LiteralPath $tempJs) {
                Remove-Item -LiteralPath $tempJs -Force
            }
        }
    }
}

$composeText = Get-Content -Raw -LiteralPath (Join-Path $root 'docker-compose.yml')
foreach ($marker in @(
    'REFERRALPILOT_IMAGE',
    'REFERRALPILOT_ALLOW_DEMO_RESET',
    'REFERRALPILOT_API_TOKEN',
    'REFERRALPILOT_REQUIRE_REVIEWER',
    'referralpilot-iris:/usr/irissys',
    '127.0.0.1:52773:52773'
)) {
    if (-not $composeText.Contains($marker)) {
        Add-Failure "docker-compose.yml is missing: $marker"
    }
}
if ($composeText -match 'REFERRALPILOT_API_TOKEN:\s*\$\{REFERRALPILOT_API_TOKEN:-') {
    Add-Warning 'Demo defaults leave the REST API tokenless; set REFERRALPILOT_API_TOKEN for shared use'
}

$dockerIgnore = Get-Content -Raw -LiteralPath (Join-Path $root '.dockerignore')
foreach ($pattern in @('.env', 'dist')) {
    if (($dockerIgnore -split "`r?`n") -notcontains $pattern) {
        Add-Failure ".dockerignore must exclude $pattern from the build context"
    }
}

foreach ($fixture in Get-ChildItem -LiteralPath (Join-Path $root 'data') -Filter '*.hl7' -File) {
    $raw = Get-Content -Raw -LiteralPath $fixture.FullName
    $segments = $raw -split "`r`n|`n|`r"
    $byName = @{}
    foreach ($segment in $segments) {
        if ($segment.Length -ge 3) {
            $byName[$segment.Substring(0, 3)] = $segment
        }
    }
    foreach ($name in @('MSH', 'PID', 'OBR', 'NTE')) {
        if (-not $byName.ContainsKey($name)) {
            Add-Failure "$($fixture.Name) is missing the $name segment"
        }
    }
    if ($byName.ContainsKey('MSH')) {
        $fields = $byName['MSH'].Split('|')
        if ($fields.Count -lt 10 -or [string]::IsNullOrWhiteSpace($fields[9])) {
            Add-Failure "$($fixture.Name) is missing MSH-10"
        }
        if ($fields.Count -lt 9 -or $fields[8] -ne 'ORM^O01') {
            Add-Failure "$($fixture.Name) must be an ORM^O01 message"
        }
    }
    if ($byName.ContainsKey('PID')) {
        $fields = $byName['PID'].Split('|')
        if ($fields.Count -lt 4 -or [string]::IsNullOrWhiteSpace($fields[3])) {
            Add-Failure "$($fixture.Name) is missing PID-3"
        }
    }
    if ($byName.ContainsKey('OBR')) {
        $fields = $byName['OBR'].Split('|')
        if ($fields.Count -lt 5 -or [string]::IsNullOrWhiteSpace($fields[4])) {
            Add-Failure "$($fixture.Name) is missing OBR-4"
        }
    }
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
    Add-Warning 'Docker CLI is not available; compose validation was skipped'
} else {
    Push-Location $root
    try {
        $composeOutput = & docker compose config -q 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "docker compose config failed: $composeOutput"
        }
        $imageTag = if ($env:REFERRALPILOT_IMAGE) {
            $env:REFERRALPILOT_IMAGE
        } else {
            'iris-community:2027.1.0AI.109.0'
        }
        & docker image inspect $imageTag *> $null
        if ($LASTEXITCODE -ne 0) {
            Add-Warning "AI Hub image $imageTag is not loaded; runtime tests cannot start"
        }
    } finally {
        Pop-Location
    }
}

foreach ($warning in $warnings) {
    Write-Host "WARN  $warning" -ForegroundColor Yellow
}
foreach ($failure in $failures) {
    Write-Host "FAIL  $failure" -ForegroundColor Red
}

if ($failures.Count -gt 0) {
    Write-Host "Static validation failed: $($failures.Count) error(s), $($warnings.Count) warning(s)." -ForegroundColor Red
    exit 1
}

Write-Host "Static validation passed: source, package metadata, fixtures, and Compose config are consistent." -ForegroundColor Green
if ($warnings.Count -gt 0) {
    Write-Host "Runtime validation still requires the missing AI Hub image." -ForegroundColor Yellow
}
exit 0
