#Requires -Version 7.0

<#
.SYNOPSIS
    Post-deployment validation for Microsoft Fabric resources.

.DESCRIPTION
    Verifies that all resources defined in the environment config exist in Fabric
    with the expected configuration. Outputs NUnit XML for the Azure DevOps test
    results tab.

    Checks performed:
      - Workspace exists       (fab ls | match  — same as Deploy-Workspaces.ps1)
      - Gateway exists         (fab ls .gateways | match — same as Deploy-Gateways.ps1)
      - Expected roles assigned (fab acl get — additive check only)
      - Git connection state   (fab api workspaces/<id>/git/connection)

    LAW (Log Analytics Workspace) validation is intentionally omitted — the
    Power BI Admin API SPN routing issue is unresolved. See docs/support.md.

    Called by the validate-deployment.yml pipeline template after each
    environment deployment. Authenticates via service principal using the
    same credential parameters as Deploy-FabricEnvironment.ps1, and logs
    out on completion (mirrors deploy behaviour for multi-env pipelines).

.PARAMETER ConfigFile
    Path to the environment configuration (YAML file or split-file directory).
    Examples:
      - parameters/necp01/weu/dev.yml        (single-file)
      - parameters/necp01/weu/dev/           (split-file with _env.yml)

.PARAMETER Environment
    Target environment name (dev | tst | prd).

.PARAMETER ClientId
    Entra application (client) ID.

.PARAMETER ClientSecret
    Client secret for service principal authentication.

.PARAMETER TenantId
    Azure AD tenant ID.

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
    [ValidateScript({ Test-Path $_ }, ErrorMessage = "Config path not found: {0}")]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

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

# ── Authenticate ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[auth] Authenticating to Microsoft Fabric..."
Invoke-FabCli -Arguments @('auth', 'logout') -AllowNonZeroExit -MaxRetries 0 | Out-Null
Invoke-FabCli -Arguments @('config', 'set', 'encryption_fallback_enabled', 'true') -MaxRetries 0 | Out-Null
Invoke-FabCli -Arguments @('auth', 'login', '-u', $ClientId, '-p', $ClientSecret, '--tenant', $TenantId) -MaxRetries 0 | Out-Null
Write-Host "[auth] Authentication successful."

try {

    $config = Read-EnvironmentConfig -ConfigPath $ConfigFile
    $testResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $startTime = Get-Date

    # ── Load workspace map ─────────────────────────────────────────────────────────
    $WorkspaceMap = @{}
    if ($WorkspaceMapFile -and (Test-Path $WorkspaceMapFile -PathType Leaf)) {
        $WorkspaceMap = Get-Content -Path $WorkspaceMapFile -Raw | ConvertFrom-Json -AsHashtable
        Write-Host "  Workspace map loaded from: $WorkspaceMapFile ($($WorkspaceMap.Count) entries)"
    }
    else {
        foreach ($ws in $config.workspaces) {
            $idResult = Invoke-FabCli -Arguments @('get', "$($ws.name).Workspace", '-q', 'id') -AllowNonZeroExit -MaxRetries 0
            if ($idResult.ExitCode -eq 0 -and $idResult.Output) {
                $wsId = "$($idResult.Output)".Trim('"').Trim()
                if ($wsId) { $WorkspaceMap[$ws.name] = $wsId }
            }
        }
        Write-Host "  Workspace IDs resolved live ($($WorkspaceMap.Count) entries)"
    }

    # ── Unwrap fab api JSON envelope ──────────────────────────────────────────────
    # fab api wraps responses: { result: { data: [{ status_code, text: <payload> }] } }
    # Mirrors Get-FabApiBody from Deploy-GitIntegration.ps1.
    function Get-FabApiBody {
        param([Parameter(Mandatory)] $FabOutput)

        if ($null -eq $FabOutput) { return $null }

        if ($FabOutput.PSObject.Properties.Name -contains 'result' -and
            $null -ne $FabOutput.result -and
            $FabOutput.result.PSObject.Properties.Name -contains 'data' -and
            $FabOutput.result.data.Count -gt 0) {
            $text = $FabOutput.result.data[0].text
            if ($text -is [string] -and $text -eq '(Empty)') { return $null }
            return $text
        }

        return $FabOutput
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
    # Uses 'fab ls | -match' — same pattern as Deploy-Workspaces.ps1.
    # 'fab exists' is unreliable for this tenant/SPN combination.
    $allWorkspaces = (Invoke-FabCli -Arguments @('ls') -AllowNonZeroExit -MaxRetries 1).Output

    foreach ($workspaceConfig in $config.workspaces) {
        $wsName = $workspaceConfig.name
        $wsFabPath = "$wsName.Workspace"
        $t = Get-Date

        # ── Workspace exists ───────────────────────────────────────────────────────
        $wsExists = $allWorkspaces -match [regex]::Escape($wsFabPath)
        Add-TestResult `
            -Name     "[$wsName] Workspace exists" `
            -Passed   ([bool]$wsExists) `
            -Message  $(if (-not $wsExists) { "Workspace '$wsName' not found in Fabric (fab ls)." }) `
            -Duration ((Get-Date) - $t).TotalSeconds

        if (-not $wsExists) { continue }

        # ── Roles assigned ─────────────────────────────────────────────────────────
        $roles = @($workspaceConfig.roles | Where-Object { $_ -and -not ($_.PSObject.Properties.Name -contains 'remove' -and $_.remove -eq $true) })
        if ($roles.Count -gt 0) {
            $t = Get-Date
            try {
                # Use JMESPath query to retrieve only principal and role fields
                $aclResult = Invoke-FabCli -Arguments @(
                    'acl', 'get', $wsFabPath,
                    '-q', '[].{principal: principal, role: role}'
                ) -JsonOutput
                
                # Normalize output shape — fab api sometimes wraps response in result.data
                $rawOutput = $aclResult.Output
                if ($rawOutput -and $rawOutput.PSObject.Properties.Name -contains 'result' -and $rawOutput.result -and $rawOutput.result.PSObject.Properties.Name -contains 'data') {
                    $currentAcls = @($rawOutput.result.data)
                } elseif ($rawOutput -is [System.Array]) {
                    $currentAcls = @($rawOutput)
                } elseif ($rawOutput -is [System.Collections.Hashtable] -or $rawOutput -is [PSCustomObject]) {
                    $currentAcls = @($rawOutput)
                } else {
                    $currentAcls = @()
                }

                foreach ($roleConfig in $roles) {
                    $identity = $roleConfig.identity
                    $desiredRole = $roleConfig.role
                    $tRole = Get-Date

                    $found = $currentAcls | Where-Object {
                        $acl = $_
                        $principalMatches = $false
                        if ($acl -and $acl.PSObject.Properties.Name -contains 'principal') {
                            $p = $acl.principal
                            if ($p -is [PSCustomObject] -and $p.PSObject.Properties.Name -contains 'id') {
                                $principalMatches = $p.id -eq $identity
                            }
                            elseif ($p -is [string]) {
                                $principalMatches = $p -eq $identity
                            }
                        }
                        if (-not $principalMatches -and $acl -and $acl.PSObject.Properties.Name -contains 'identity') {
                            $principalMatches = $acl.identity -eq $identity
                        }
                        if (-not $principalMatches -and $acl -and $acl.PSObject.Properties.Name -contains 'id') {
                            $principalMatches = $acl.id -eq $identity
                        }
                        
                        $principalMatches -and $acl -and $acl.PSObject.Properties.Name -contains 'role' -and $acl.role -eq $desiredRole
                    } | Select-Object -First 1

                    Add-TestResult `
                        -Name     "[$wsName] Role '$desiredRole' assigned to '$identity'" `
                        -Passed   ($null -ne $found) `
                        -Message  $(if (-not $found) { "Role '$desiredRole' not assigned to '$identity' in '$wsName'." }) `
                        -Duration ((Get-Date) - $tRole).TotalSeconds
                }
            }
            catch {
                Add-TestResult `
                    -Name    "[$wsName] ACL check" `
                    -Passed  $false `
                    -Message "Failed to retrieve ACLs for '$wsName': $_" `
                    -Duration ((Get-Date) - $t).TotalSeconds
            }
        }

        # ── Git integration state ──────────────────────────────────────────────────
        $hasGit = $workspaceConfig.PSObject.Properties.Name -contains 'gitIntegration'
        $gitConfig = if ($hasGit) { $workspaceConfig.gitIntegration } else { $null }

        if ($hasGit -and $gitConfig -ne $false -and $null -ne $gitConfig) {
            $wsId = $WorkspaceMap[$wsName]

            if ($wsId) {
                $tGit = Get-Date
                try {
                    $gitResult = Invoke-FabCli -Arguments @(
                        'api', "workspaces/$wsId/git/connection"
                    ) -MaxRetries 2 -JsonOutput
                    $gitConn = Get-FabApiBody -FabOutput $gitResult.Output

                    $connState = if ($gitConn -and $gitConn.PSObject.Properties.Name -contains 'gitConnectionState') {
                        $gitConn.gitConnectionState
                    }
                    else { 'Unknown' }

                    Add-TestResult `
                        -Name     "[$wsName] Git connection state is ConnectedAndInitialized" `
                        -Passed   ($connState -eq 'ConnectedAndInitialized') `
                        -Message  $(if ($connState -ne 'ConnectedAndInitialized') { "Expected ConnectedAndInitialized but got '$connState'." }) `
                        -Duration ((Get-Date) - $tGit).TotalSeconds

                    if ($connState -eq 'ConnectedAndInitialized' -and $gitConn.gitProviderDetails) {
                        $details = $gitConn.gitProviderDetails

                        Add-TestResult `
                            -Name     "[$wsName] Git connected to correct repository '$($gitConfig.repositoryName)'" `
                            -Passed   ($details.repositoryName -eq $gitConfig.repositoryName) `
                            -Message  $(if ($details.repositoryName -ne $gitConfig.repositoryName) {
                                "Expected '$($gitConfig.repositoryName)' but got '$($details.repositoryName)'."
                            }) `
                            -Duration 0

                        Add-TestResult `
                            -Name     "[$wsName] Git connected to correct branch '$($gitConfig.branchName)'" `
                            -Passed   ($details.branchName -eq $gitConfig.branchName) `
                            -Message  $(if ($details.branchName -ne $gitConfig.branchName) {
                                "Expected '$($gitConfig.branchName)' but got '$($details.branchName)'."
                            }) `
                            -Duration 0
                    }
                }
                catch {
                    Add-TestResult `
                        -Name    "[$wsName] Git connection check" `
                        -Passed  $false `
                        -Message "Failed to retrieve Git connection for '$wsName': $_" `
                        -Duration ((Get-Date) - $tGit).TotalSeconds
                }
            }
            else {
                Add-TestResult `
                    -Name    "[$wsName] Git connection check" `
                    -Passed  $false `
                    -Message "Workspace '$wsName' not found in workspace map; cannot verify Git connection." `
                    -Duration 0
            }
        }

        # ── Log Analytics ──────────────────────────────────────────────────────────
        # TODO: LAW validation omitted — Power BI Admin API SPN routing unresolved.
        # See docs/support.md and Deploy-LogAnalytics.ps1 for context.
        # Re-enable once SPN access via api.powerbi.com or regional endpoint is confirmed stable.
    }

    # ── Validate gateways ──────────────────────────────────────────────────────────
    # Uses 'fab ls .gateways | -match' — same pattern as Deploy-Gateways.ps1.
    $hasGateways = $config.PSObject.Properties.Name -contains 'gateways'
    if ($hasGateways -and $config.gateways.Count -gt 0) {

        $allGateways = (Invoke-FabCli -Arguments @('ls', '.gateways') -AllowNonZeroExit -MaxRetries 1).Output

        foreach ($gwConfig in $config.gateways) {
            $gwName = $gwConfig.name
            $gwFabPath = ".gateways/$gwName.Gateway"

            # ── Gateway exists ─────────────────────────────────────────────────────
            $tGw = Get-Date
            $gwExists = $allGateways -match [regex]::Escape($gwName)
            Add-TestResult `
                -Name     "[Gateway:$gwName] Gateway exists" `
                -Passed   ([bool]$gwExists) `
                -Message  $(if (-not $gwExists) { "VNet Data Gateway '$gwName' not found in Fabric (fab ls .gateways)." }) `
                -Duration ((Get-Date) - $tGw).TotalSeconds

            if (-not $gwExists) { continue }

            # ── Gateway settings ───────────────────────────────────────────────────
            $tSettings = Get-Date
            try {
                $gwGetResult = Invoke-FabCli -Arguments @('get', $gwFabPath) -MaxRetries 2 -JsonOutput
                $gwDetails = $gwGetResult.Output

                if ($gwConfig.PSObject.Properties.Name -contains 'numberOfMemberGateways' -and
                    $null -ne $gwConfig.numberOfMemberGateways -and
                    $gwDetails -and $gwDetails.PSObject.Properties.Name -contains 'numberOfMemberGateways') {

                    $membersMatch = $gwDetails.numberOfMemberGateways -eq $gwConfig.numberOfMemberGateways
                    Add-TestResult `
                        -Name     "[Gateway:$gwName] numberOfMemberGateways = $($gwConfig.numberOfMemberGateways)" `
                        -Passed   $membersMatch `
                        -Message  $(if (-not $membersMatch) {
                            "Expected $($gwConfig.numberOfMemberGateways) but got $($gwDetails.numberOfMemberGateways)."
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
                            "Expected $($gwConfig.inactivityMinutesBeforeSleep) but got $($gwDetails.inactivityMinutesBeforeSleep)."
                        }) `
                        -Duration 0
                }
            }
            catch {
                Add-TestResult `
                    -Name    "[Gateway:$gwName] Settings check" `
                    -Passed  $false `
                    -Message "Failed to retrieve gateway details for '$gwName': $_" `
                    -Duration ((Get-Date) - $tSettings).TotalSeconds
            }
        }
    }

    # ── NUnit XML ──────────────────────────────────────────────────────────────────
    $totalDuration = ((Get-Date) - $startTime).TotalSeconds
    $passed = @($testResults | Where-Object { $_.Result -eq 'Pass' }).Count
    $failed = @($testResults | Where-Object { $_.Result -eq 'Fail' }).Count
    $total = $testResults.Count

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
        }
        else {
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

}
finally {
    # Mirror Deploy-FabricEnvironment.ps1 step 10 — clear credentials so
    # subsequent environments on the same agent don't get stale auth state.
    Write-Host ""
    Write-Host "[auth] Logging out of Fabric CLI..."
    Invoke-FabCli -Arguments @('auth', 'logout') -AllowNonZeroExit -MaxRetries 0 | Out-Null
}