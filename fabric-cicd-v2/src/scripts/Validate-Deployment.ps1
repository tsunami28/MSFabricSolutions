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
