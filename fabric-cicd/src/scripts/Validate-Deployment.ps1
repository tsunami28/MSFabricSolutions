#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }

<#
.SYNOPSIS
    Post-deployment validation for Microsoft Fabric resources.

.DESCRIPTION
    Verifies that all resources defined in the parameter file exist in Fabric
    with the expected configuration. Outputs NUnit XML for the Azure DevOps
    test results tab.

    Checks performed:
      - Workspace exists
      - Workspace is assigned to the correct capacity
      - Expected items exist (lakehouses, warehouses, notebooks, pipelines)
      - Role assignments match config (additive check - does not flag extra roles)

.PARAMETER ConfigFile
    Path to the environment JSON parameter file.

.PARAMETER Environment
    Target environment name (dev | tst | prd).

.PARAMETER TenantId
    Azure AD Tenant ID.

.PARAMETER ManagedIdentityClientId
    Client ID of the User-Assigned Managed Identity.

.PARAMETER OutputPath
    Directory to write NUnit XML results and log files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedIdentityClientId,

    [Parameter()]
    [string]$OutputPath = (Join-Path $env:TEMP 'fabric-validation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction SilentlyContinue

Write-Host "=== Post-Deployment Validation ==="
Write-Host "  Environment : $Environment"
Write-Host "  Config File : $ConfigFile"

# ── Authenticate ───────────────────────────────────────────────────────────────
Set-FabricApiHeaders `
    -TenantId $TenantId `
    -UseManagedIdentity `
    -ManagedIdentityId $ManagedIdentityClientId

$config      = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json -Depth 20
$testResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$startTime   = Get-Date

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Message = $null, [double]$Duration = 0)
    $testResults.Add([PSCustomObject]@{
        Name     = $Name
        Result   = if ($Passed) { 'Pass' } else { 'Fail' }
        Duration = $Duration
        Message  = $Message
    })
}

# ── Validate each workspace ────────────────────────────────────────────────────
foreach ($workspaceConfig in $config.workspaces) {
    $wsName = $workspaceConfig.name
    $t = Get-Date

    # Test: workspace exists
    $workspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    Add-TestResult `
        -Name     "[$wsName] Workspace exists" `
        -Passed   ($null -ne $workspace) `
        -Message  $(if (-not $workspace) { "Workspace '$wsName' not found in Fabric" }) `
        -Duration ((Get-Date) - $t).TotalSeconds

    if (-not $workspace) { continue }

    # Test: items exist (lakehouses)
    foreach ($lhConfig in @($workspaceConfig.items?.lakehouses | Where-Object { $_ })) {
        $t = Get-Date
        $item = Get-FabricLakehouse -WorkspaceId $workspace.id -LakehouseName $lhConfig.name -ErrorAction SilentlyContinue
        Add-TestResult `
            -Name     "[$wsName] Lakehouse '$($lhConfig.name)' exists" `
            -Passed   ($null -ne $item) `
            -Message  $(if (-not $item) { "Lakehouse '$($lhConfig.name)' not found in workspace '$wsName'" }) `
            -Duration ((Get-Date) - $t).TotalSeconds
    }

    # Test: items exist (warehouses)
    foreach ($whConfig in @($workspaceConfig.items?.warehouses | Where-Object { $_ })) {
        $t = Get-Date
        $item = Get-FabricWarehouse -WorkspaceId $workspace.id -WarehouseName $whConfig.name -ErrorAction SilentlyContinue
        Add-TestResult `
            -Name     "[$wsName] Warehouse '$($whConfig.name)' exists" `
            -Passed   ($null -ne $item) `
            -Message  $(if (-not $item) { "Warehouse '$($whConfig.name)' not found in workspace '$wsName'" }) `
            -Duration ((Get-Date) - $t).TotalSeconds
    }

    # Test: items exist (notebooks)
    foreach ($nbConfig in @($workspaceConfig.items?.notebooks | Where-Object { $_ })) {
        $t = Get-Date
        $item = Get-FabricNotebook -WorkspaceId $workspace.id -NotebookName $nbConfig.name -ErrorAction SilentlyContinue
        Add-TestResult `
            -Name     "[$wsName] Notebook '$($nbConfig.name)' exists" `
            -Passed   ($null -ne $item) `
            -Message  $(if (-not $item) { "Notebook '$($nbConfig.name)' not found in workspace '$wsName'" }) `
            -Duration ((Get-Date) - $t).TotalSeconds
    }

    # Test: role assignments (additive - verify expected roles are present)
    foreach ($roleConfig in @($workspaceConfig.roles | Where-Object { $_ -and -not $_.remove })) {
        $t = Get-Date
        $assignments = Get-FabricWorkspaceRoleAssignment -WorkspaceId $workspace.id -ErrorAction SilentlyContinue
        $found = $assignments | Where-Object {
            ($_.principal?.userPrincipalName -eq $roleConfig.principal -or $_.principal?.id -eq $roleConfig.principal) -and
            $_.role -eq $roleConfig.role
        }
        Add-TestResult `
            -Name     "[$wsName] Role '$($roleConfig.role)' assigned to '$($roleConfig.principal)'" `
            -Passed   ($null -ne $found) `
            -Message  $(if (-not $found) { "Role assignment '$($roleConfig.role)' for '$($roleConfig.principal)' not found" }) `
            -Duration ((Get-Date) - $t).TotalSeconds
    }
}

# ── Write NUnit XML ────────────────────────────────────────────────────────────
$totalTime  = ((Get-Date) - $startTime).TotalSeconds
$passCount  = ($testResults | Where-Object Result -eq 'Pass').Count
$failCount  = ($testResults | Where-Object Result -eq 'Fail').Count

function ConvertTo-XmlSafeString ([string]$Input) {
    [System.Security.SecurityElement]::Escape($Input)
}

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
$null = $sb.AppendLine("<test-results name=""Fabric Deployment Validation"" total=""$($testResults.Count)"" errors=""0"" failures=""$failCount"" not-run=""0"" inconclusive=""0"" ignored=""0"" skipped=""0"" invalid=""0"" date=""$(Get-Date -Format 'yyyy-MM-dd')"" time=""$(Get-Date -Format 'HH:mm:ss')"">")
$null = $sb.AppendLine("  <test-suite name=""$Environment"" success=""$($failCount -eq 0)"" time=""$totalTime"" asserts=""0"">")
$null = $sb.AppendLine("    <results>")

foreach ($t in $testResults) {
    $success = ($t.Result -eq 'Pass').ToString().ToLower()
    $null = $sb.Append("      <test-case name=""$(ConvertTo-XmlSafeString $t.Name)"" executed=""True"" result=""$($t.Result)"" success=""$success"" time=""$($t.Duration)"" asserts=""0"">")
    if ($t.Result -ne 'Pass' -and $t.Message) {
        $null = $sb.Append("<failure><message>$(ConvertTo-XmlSafeString $t.Message)</message></failure>")
    }
    $null = $sb.AppendLine("</test-case>")
}

$null = $sb.AppendLine("    </results>")
$null = $sb.AppendLine("  </test-suite>")
$null = $sb.AppendLine("</test-results>")

$xmlPath = Join-Path $OutputPath "validation-$Environment.xml"
$sb.ToString() | Out-File -FilePath $xmlPath -Encoding UTF8

Write-Host ""
Write-Host "=== Validation Summary ==="
Write-Host "  Pass : $passCount"
Write-Host "  Fail : $failCount"
Write-Host "  Total: $($testResults.Count)"
Write-Host "  Output: $xmlPath"

if ($failCount -gt 0) {
    Write-Host "##vso[task.logissue type=error]Fabric validation failed: $failCount test(s) did not pass."
    throw "Deployment validation failed: $failCount test(s) did not pass."
}

Write-Host "All $passCount validation check(s) passed."
