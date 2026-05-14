#Requires -Version 7.0

<#
.SYNOPSIS
    Post-deployment validation for Microsoft Fabric resources.

.DESCRIPTION
    Verifies that all resources defined in the environment config exist in Fabric
    with the expected configuration. Outputs NUnit XML for the Azure DevOps test
    results tab.

    Checks performed:
      - Workspace exists (fab exists)
      - Expected roles are assigned (fab acl get - additive check only)
      - Item deployment report available from fab deploy output (best-effort)

    Called by the validate-deployment.yml pipeline template after each
    environment deployment. Assumes 'fab auth login' has already been called.

.PARAMETER ConfigFile
    Path to the environment YAML parameter file.

.PARAMETER Environment
    Target environment name (dev | tst | prd).

.PARAMETER WorkspaceMapFile
    Optional path to a workspace-map.json file produced by Deploy-FabricEnvironment.
    Required to validate Git integration state. When omitted, workspace IDs are
    resolved live via 'fab get'.

.PARAMETER OutputPath
    Directory to write NUnit XML results.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter()]
    [string]$WorkspaceMapFile = '',

    [Parameter()]
    [string]$OutputPath = (Join-Path $env:TEMP "fabric-validation-$Environment")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsRoot = $PSScriptRoot
$helpersRoot = Join-Path $scriptsRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')
. (Join-Path $helpersRoot 'Read-EnvironmentConfig.ps1')

$null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction SilentlyContinue

Write-Host "=== Post-Deployment Validation ==="
Write-Host "  Environment : $Environment"
Write-Host "  Config File : $ConfigFile"

$config      = Read-EnvironmentConfig -ConfigPath $ConfigFile
$testResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$startTime   = Get-Date

# ── Load workspace map (needed for Git integration checks) ─────────────────────
$WorkspaceMap = @{}
if ($WorkspaceMapFile -and (Test-Path $WorkspaceMapFile -PathType Leaf)) {
    $WorkspaceMap = Get-Content -Path $WorkspaceMapFile -Raw | ConvertFrom-Json -AsHashtable
    Write-Host "  Workspace map loaded from: $WorkspaceMapFile ($($WorkspaceMap.Count) entries)"
} else {
    # Resolve IDs live when map file is not provided
    foreach ($ws in $config.workspaces) {
        $idResult = Invoke-FabCli -Arguments @('get', "$($ws.name).Workspace", '-q', 'id') -AllowNonZeroExit -MaxRetries 0
        if ($idResult.ExitCode -eq 0 -and $idResult.Output) {
            $wsId = "$($idResult.Output)".Trim('"').Trim()
            if ($wsId) { $WorkspaceMap[$ws.name] = $wsId }
        }
    }
    Write-Host "  Workspace IDs resolved live ($($WorkspaceMap.Count) entries)"
}

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Message = '', [double]$Duration = 0)
    $testResults.Add([PSCustomObject]@{
        Name     = $Name
        Result   = if ($Passed) { 'Pass' } else { 'Fail' }
        Duration = [Math]::Round($Duration, 3)
        Message  = $Message
    })
    $icon = if ($Passed) { '  [PASS]' } else { '  [FAIL]' }
    Write-Host "$icon $Name$(if (-not $Passed -and $Message) { " - $Message" })"
}

# ── Validate each workspace ────────────────────────────────────────────────────
foreach ($workspaceConfig in $config.workspaces) {
    $wsName    = $workspaceConfig.name
    $wsFabPath = "$wsName.Workspace"
    $t         = Get-Date

    # Test: workspace exists
    $wsExists = Test-FabResourceExists -Path $wsFabPath
    Add-TestResult `
        -Name     "[$wsName] Workspace exists" `
        -Passed   $wsExists `
        -Message  $(if (-not $wsExists) { "Workspace '$wsName' not found in Fabric." }) `
        -Duration ((Get-Date) - $t).TotalSeconds

    if (-not $wsExists) { continue }

    # Test: required roles are assigned
    $roles = @($workspaceConfig.roles | Where-Object { $_ -and -not $_.remove })
    if ($roles.Count -gt 0) {
        $t = Get-Date
        try {
            $aclResult   = Invoke-FabCli -Arguments @('acl', 'get', $wsFabPath, '--output_format', 'json')
            $currentAcls = @($aclResult.Output)

            foreach ($roleConfig in $roles) {
                $identity    = $roleConfig.identity
                $desiredRole = $roleConfig.role
                $tRole       = Get-Date

                $found = $currentAcls | Where-Object {
                    ($_.principal?.id -eq $identity -or $_.principal -eq $identity) -and
                    $_.role -eq $desiredRole
                }

                Add-TestResult `
                    -Name     "[$wsName] Role '$desiredRole' assigned to '$identity'" `
                    -Passed   ($null -ne $found) `
                    -Message  $(if (-not $found) { "Role '$desiredRole' not assigned to identity '$identity' in workspace '$wsName'." }) `
                    -Duration ((Get-Date) - $tRole).TotalSeconds
            }
        } catch {
            Add-TestResult `
                -Name    "[$wsName] ACL check" `
                -Passed  $false `
                -Message "Failed to retrieve ACLs for '$wsName': $_" `
                -Duration ((Get-Date) - $t).TotalSeconds
        }
    }

    # Test: Git integration state (when gitIntegration block is present and not false)
    $hasGit    = $workspaceConfig.PSObject.Properties.Name -contains 'gitIntegration'
    $gitConfig = if ($hasGit) { $workspaceConfig.gitIntegration } else { $null }

    if ($hasGit -and $gitConfig -ne $false -and $null -ne $gitConfig) {
        $wsId = $WorkspaceMap[$wsName]

        if ($wsId) {
            $tGit = Get-Date
            try {
                $gitResult = Invoke-FabCli -Arguments @(
                    'api', "workspaces/$wsId/git/connection", '--output_format', 'json'
                ) -MaxRetries 2
                $gitConn = $gitResult.Output

                $connState = if ($gitConn -and $gitConn.PSObject.Properties.Name -contains 'gitConnectionState') {
                    $gitConn.gitConnectionState
                } else { 'Unknown' }

                Add-TestResult `
                    -Name     "[$wsName] Git connection state is ConnectedAndInitialized" `
                    -Passed   ($connState -eq 'ConnectedAndInitialized') `
                    -Message  $(if ($connState -ne 'ConnectedAndInitialized') { "Expected ConnectedAndInitialized but got '$connState' for workspace '$wsName'." }) `
                    -Duration ((Get-Date) - $tGit).TotalSeconds

                if ($connState -eq 'ConnectedAndInitialized' -and $gitConn.gitProviderDetails) {
                    $details = $gitConn.gitProviderDetails

                    Add-TestResult `
                        -Name     "[$wsName] Git connected to correct repository '$($gitConfig.repositoryName)'" `
                        -Passed   ($details.repositoryName -eq $gitConfig.repositoryName) `
                        -Message  $(if ($details.repositoryName -ne $gitConfig.repositoryName) {
                            "Expected repositoryName '$($gitConfig.repositoryName)' but got '$($details.repositoryName)'." }) `
                        -Duration 0

                    Add-TestResult `
                        -Name     "[$wsName] Git connected to correct branch '$($gitConfig.branchName)'" `
                        -Passed   ($details.branchName -eq $gitConfig.branchName) `
                        -Message  $(if ($details.branchName -ne $gitConfig.branchName) {
                            "Expected branchName '$($gitConfig.branchName)' but got '$($details.branchName)'." }) `
                        -Duration 0
                }
            } catch {
                Add-TestResult `
                    -Name    "[$wsName] Git connection check" `
                    -Passed  $false `
                    -Message "Failed to retrieve Git connection for '$wsName': $_" `
                    -Duration ((Get-Date) - $tGit).TotalSeconds
            }
        } else {
            Add-TestResult `
                -Name    "[$wsName] Git connection check" `
                -Passed  $false `
                -Message "Workspace '$wsName' not found in workspace map; cannot verify Git connection." `
                -Duration 0
        }
    }
}

# ── Validate gateways ──────────────────────────────────────────────────────────
$hasGateways = $config.PSObject.Properties.Name -contains 'gateways'
if ($hasGateways -and $config.gateways.Count -gt 0) {
    foreach ($gwConfig in $config.gateways) {
        $gwName    = $gwConfig.name
        $gwFabPath = ".gateways/$gwName.Gateway"

        # Test: gateway exists
        $tGw      = Get-Date
        $gwExists = Test-FabResourceExists -Path $gwFabPath
        Add-TestResult `
            -Name     "[Gateway:$gwName] Gateway exists" `
            -Passed   $gwExists `
            -Message  $(if (-not $gwExists) { "VNet Data Gateway '$gwName' not found in Fabric." }) `
            -Duration ((Get-Date) - $tGw).TotalSeconds

        if (-not $gwExists) { continue }

        # Test: gateway settings match desired state
        $tSettings   = Get-Date
        try {
            $gwGetResult = Invoke-FabCli -Arguments @('get', $gwFabPath, '--output_format', 'json') -MaxRetries 2
            $gwDetails   = $gwGetResult.Output

            if ($gwConfig.PSObject.Properties.Name -contains 'numberOfMemberGateways' -and
                $null -ne $gwConfig.numberOfMemberGateways -and
                $gwDetails -and $gwDetails.PSObject.Properties.Name -contains 'numberOfMemberGateways') {
                $membersMatch = $gwDetails.numberOfMemberGateways -eq $gwConfig.numberOfMemberGateways
                Add-TestResult `
                    -Name     "[Gateway:$gwName] numberOfMemberGateways = $($gwConfig.numberOfMemberGateways)" `
                    -Passed   $membersMatch `
                    -Message  $(if (-not $membersMatch) {
                        "Expected numberOfMemberGateways=$($gwConfig.numberOfMemberGateways) but got $($gwDetails.numberOfMemberGateways)."
                    }) `
                    -Duration ((Get-Date) - $tSettings).TotalSeconds
            }

            if ($gwConfig.PSObject.Properties.Name -contains 'inactivityMinutesBeforeSleep' -and
                $null -ne $gwConfig.inactivityMinutesBeforeSleep -and
                $gwDetails -and $gwDetails.PSObject.Properties.Name -contains 'inactivityMinutesBeforeSleep') {
                $sleepMatch = $gwDetails.inactivityMinutesBeforeSleep -eq $gwConfig.inactivityMinutesBeforeSleep
                Add-TestResult `
                    -Name     "[Gateway:$gwName] inactivityMinutesBeforeSleep = $($gwConfig.inactivityMinutesBeforeSleep)" `
                    -Passed   $sleepMatch `
                    -Message  $(if (-not $sleepMatch) {
                        "Expected inactivityMinutesBeforeSleep=$($gwConfig.inactivityMinutesBeforeSleep) but got $($gwDetails.inactivityMinutesBeforeSleep)."
                    }) `
                    -Duration 0
            }
        } catch {
            Add-TestResult `
                -Name    "[Gateway:$gwName] Settings check" `
                -Passed  $false `
                -Message "Failed to retrieve gateway details for '$gwName': $_" `
                -Duration ((Get-Date) - $tSettings).TotalSeconds
        }
    }
}

# ── Emit NUnit XML ─────────────────────────────────────────────────────────────
$totalDuration = ((Get-Date) - $startTime).TotalSeconds
$passed        = @($testResults | Where-Object { $_.Result -eq 'Pass' }).Count
$failed        = @($testResults | Where-Object { $_.Result -eq 'Fail' }).Count
$total         = $testResults.Count

Write-Host ""
Write-Host "=== Validation Summary ==="
Write-Host "  Total : $total"
Write-Host "  Passed: $passed"
Write-Host "  Failed: $failed"

$xmlPath = Join-Path $OutputPath "fabric-validation-$Environment.xml"

$caseXml = foreach ($t in $testResults) {
    $nameEscaped = [System.Security.SecurityElement]::Escape($t.Name)
    if ($t.Result -eq 'Pass') {
        "    <test-case name=`"$nameEscaped`" result=`"Passed`" time=`"$($t.Duration)`" />"
    } else {
        $msgEscaped = [System.Security.SecurityElement]::Escape($t.Message)
        @"
    <test-case name="$nameEscaped" result="Failed" time="$($t.Duration)">
      <failure>
        <message>$msgEscaped</message>
      </failure>
    </test-case>
"@
    }
}

$nunit = @"
<?xml version="1.0" encoding="utf-8"?>
<test-results name="Fabric Validation - $Environment" total="$total" errors="0" failures="$failed" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0" date="$(Get-Date -Format 'yyyy-MM-dd')" time="$(Get-Date -Format 'HH:mm:ss')">
  <test-suite name="Fabric Deployment Validation" success="$(if ($failed -eq 0) {'True'} else {'False'})" time="$([Math]::Round($totalDuration,3))" asserts="$total">
    <results>
$($caseXml -join "`n")
    </results>
  </test-suite>
</test-results>
"@

Set-Content -Path $xmlPath -Value $nunit -Encoding UTF8
Write-Host "  NUnit XML: $xmlPath"

if ($failed -gt 0) {
    Write-Host "##vso[task.logissue type=error]$failed validation check(s) failed for environment '$Environment'."
    exit 1
}
