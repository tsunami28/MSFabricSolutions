#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }
#Requires -Modules @{ ModuleName = 'PSFramework'; ModuleVersion = '1.12.0' }
#Requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Detects configuration drift between the parameter file and live Fabric state.

.DESCRIPTION
    Compares every resource defined in the environment JSON against what exists in
    Fabric and reports discrepancies in two formats:

      - NUnit XML  → consumed by PublishTestResults@2 (ADO Tests tab)
      - JSON report → published as an artifact for human review

    Checks performed (config → Fabric direction):
      - Workspace exists
      - Workspace capacity assignment matches parameter file
      - Item existence and description drift (lakehouse, warehouse, notebook,
        data pipeline, Spark environment, Spark job definition)
      - Connection existence (by display name)
      - Role assignments present

    Orphaned resources (Fabric → config direction):
      - Items present in Fabric but absent from config are recorded as warnings
        only and do NOT cause the script to exit non-zero.

    The script always exits 0. Use the NUnit XML with PublishTestResults@2
    (failTaskOnFailedTests: true) to fail the ADO job when drift is found.

.PARAMETER ConfigFile
    Path to the environment JSON parameter file (e.g. config/environments/dev.json).

.PARAMETER Environment
    Target environment: dev | tst | prd.

.PARAMETER TenantId
    Azure AD / Entra ID tenant GUID.

.PARAMETER ManagedIdentityClientId
    Client ID of the User-Assigned Managed Identity used for Fabric auth.

.PARAMETER CapacitiesFile
    Path to config/shared/capacities.json. Defaults to the sibling directory
    relative to this script.

.PARAMETER OutputDirectory
    Directory where drift-<env>.xml and drift-report-<env>.json are written.
    Defaults to $env:TEMP/fabric-drift.

.NOTES
    Phase 6 implementation. Called by detect-environment-drift.yml template via
    AzurePowerShell@5. Set-FabricApiHeaders is called internally.
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
    [string]$CapacitiesFile = (Join-Path $PSScriptRoot '../../config/shared/capacities.json'),

    [Parameter()]
    [string]$OutputDirectory = (Join-Path $env:TEMP 'fabric-drift')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── REST helper (needed for connection checks) ─────────────────────────────────
. (Join-Path $PSScriptRoot '../helpers/Invoke-FabricRestMethod.ps1')

# ── Output directory ───────────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction SilentlyContinue

Write-Host "=== Fabric Drift Detection ==="
Write-Host "  Environment  : $Environment"
Write-Host "  Config File  : $ConfigFile"
Write-Host "  Output Dir   : $OutputDirectory"
Write-Host ""

# ── Authenticate ───────────────────────────────────────────────────────────────
Set-FabricApiHeaders `
    -TenantId $TenantId `
    -UseManagedIdentity `
    -ManagedIdentityId $ManagedIdentityClientId

# ── Load config ────────────────────────────────────────────────────────────────
$config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json -Depth 20

# ── Load capacity map ──────────────────────────────────────────────────────────
$capacityMap = @{}
if (Test-Path $CapacitiesFile) {
    $capacitiesRaw = Get-Content -Path $CapacitiesFile -Raw | ConvertFrom-Json
    if ($capacitiesRaw.$Environment) {
        foreach ($prop in $capacitiesRaw.$Environment.PSObject.Properties) {
            $capacityMap[$prop.Name] = $prop.Value
        }
    }
}

# ── Result collections ─────────────────────────────────────────────────────────
$checks   = [System.Collections.Generic.List[PSCustomObject]]::new()
$warnings = [System.Collections.Generic.List[PSCustomObject]]::new()
$startTime = Get-Date

function Add-Check {
    param(
        [string]$Category,
        [string]$Workspace,
        [string]$Resource,
        [string]$CheckName,
        [ValidateSet('Pass', 'Fail')]
        [string]$Status,
        [string]$Expected = $null,
        [string]$Actual   = $null
    )
    $script:checks.Add([PSCustomObject]@{
        category  = $Category
        workspace = $Workspace
        resource  = $Resource
        check     = $CheckName
        status    = $Status
        expected  = $Expected
        actual    = $Actual
    })
    if ($Status -eq 'Fail') {
        $msg = "DRIFT [$Category] $Workspace / $Resource [$CheckName]"
        if ($Expected) { $msg += "  expected='$Expected'" }
        if ($Actual)   { $msg += "  actual='$Actual'" }
        Write-Host "##vso[task.logissue type=error]$msg"
        Write-PSFMessage -Level Warning -Message $msg
    }
}

function Add-Warning {
    param([string]$Category, [string]$Workspace, [string]$Resource, [string]$Message)
    $script:warnings.Add([PSCustomObject]@{
        category  = $Category
        workspace = $Workspace
        resource  = $Resource
        message   = $Message
    })
    Write-PSFMessage -Level Warning -Message "  [ORPHANED] $Message"
}

# ── Helper: check description drift ───────────────────────────────────────────
function Test-Description {
    param([string]$Workspace, [string]$Category, [string]$Resource,
          [string]$Expected, [string]$Actual)
    if ($Expected) {
        $matches = ($Actual -eq $Expected)
        Add-Check -Category $Category -Workspace $Workspace -Resource $Resource `
            -CheckName 'description' -Status ($matches ? 'Pass' : 'Fail') `
            -Expected $Expected -Actual ($Actual ?? '')
    }
}

# ── Cache Fabric connections (fetched once to avoid repeated REST calls) ───────
$fabricConnectionsCache = $null

function Get-FabricConnectionsCache {
    if ($null -eq $script:fabricConnectionsCache) {
        try {
            $resp = Invoke-FabricRestMethod -Method GET -RelativeUri 'connections'
            $script:fabricConnectionsCache = @($resp.value)
        } catch {
            Write-PSFMessage -Level Warning -Message "Could not retrieve Fabric connections: $_"
            $script:fabricConnectionsCache = @()
        }
    }
    return $script:fabricConnectionsCache
}

# ══════════════════════════════════════════════════════════════════════════════
# PER-WORKSPACE CHECKS
# ══════════════════════════════════════════════════════════════════════════════
foreach ($wsConfig in $config.workspaces) {
    $wsName = $wsConfig.name
    Write-PSFMessage -Level Host -Message "Checking workspace: $wsName"

    # ── 1. Workspace exists ────────────────────────────────────────────────────
    $fabricWs = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    Add-Check -Category 'Workspaces' -Workspace $wsName -Resource $wsName `
        -CheckName 'exists' -Status ($fabricWs ? 'Pass' : 'Fail') `
        -Expected 'Exists' -Actual ($fabricWs ? 'Exists' : 'NotFound')

    if (-not $fabricWs) {
        Write-PSFMessage -Level Warning -Message "  Workspace '$wsName' not found - skipping item/security checks"
        continue
    }

    # ── 2. Capacity assignment ─────────────────────────────────────────────────
    $expectedCapacityName = if ($wsConfig.capacityOverride) {
        $wsConfig.capacityOverride
    } else {
        $config.capacityName
    }

    if ($expectedCapacityName -and $capacityMap.ContainsKey($expectedCapacityName)) {
        $expectedId = $capacityMap[$expectedCapacityName]
        $actualId   = $fabricWs.capacityId
        Add-Check -Category 'Workspaces' -Workspace $wsName -Resource "$wsName/capacity" `
            -CheckName 'capacityId' -Status ($actualId -eq $expectedId ? 'Pass' : 'Fail') `
            -Expected $expectedId -Actual ($actualId ?? 'null')
    }

    # ══════════════════════════════════════════════════════════════════════════
    # ITEM CHECKS
    # ══════════════════════════════════════════════════════════════════════════
    $items = $wsConfig.items

    # ── 3a. Lakehouses ─────────────────────────────────────────────────────────
    $fabricLakehouses = @(Get-FabricLakehouse -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)
    $configLhNames    = @($items?.lakehouses | Where-Object { $_ } | Select-Object -ExpandProperty name)

    foreach ($lhConfig in @($items?.lakehouses | Where-Object { $_ })) {
        $fabricLh = $fabricLakehouses | Where-Object { $_.displayName -eq $lhConfig.name }
        Add-Check -Category 'Items' -Workspace $wsName -Resource "Lakehouse:$($lhConfig.name)" `
            -CheckName 'exists' -Status ($fabricLh ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($fabricLh ? 'Exists' : 'NotFound')
        if ($fabricLh) {
            Test-Description -Workspace $wsName -Category 'Items' `
                -Resource "Lakehouse:$($lhConfig.name)" `
                -Expected $lhConfig.description -Actual $fabricLh.description
        }
    }
    # Orphaned lakehouses
    foreach ($fabricLh in $fabricLakehouses) {
        if ($fabricLh.displayName -notin $configLhNames) {
            Add-Warning -Category 'Items' -Workspace $wsName `
                -Resource "Lakehouse:$($fabricLh.displayName)" `
                -Message "Lakehouse '$($fabricLh.displayName)' exists in Fabric but is not in config (workspace: $wsName)"
        }
    }

    # ── 3b. Warehouses ─────────────────────────────────────────────────────────
    $fabricWarehouses = @(Get-FabricWarehouse -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)
    $configWhNames    = @($items?.warehouses | Where-Object { $_ } | Select-Object -ExpandProperty name)

    foreach ($whConfig in @($items?.warehouses | Where-Object { $_ })) {
        $fabricWh = $fabricWarehouses | Where-Object { $_.displayName -eq $whConfig.name }
        Add-Check -Category 'Items' -Workspace $wsName -Resource "Warehouse:$($whConfig.name)" `
            -CheckName 'exists' -Status ($fabricWh ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($fabricWh ? 'Exists' : 'NotFound')
        if ($fabricWh) {
            Test-Description -Workspace $wsName -Category 'Items' `
                -Resource "Warehouse:$($whConfig.name)" `
                -Expected $whConfig.description -Actual $fabricWh.description
        }
    }
    foreach ($fabricWh in $fabricWarehouses) {
        if ($fabricWh.displayName -notin $configWhNames) {
            Add-Warning -Category 'Items' -Workspace $wsName `
                -Resource "Warehouse:$($fabricWh.displayName)" `
                -Message "Warehouse '$($fabricWh.displayName)' exists in Fabric but is not in config (workspace: $wsName)"
        }
    }

    # ── 3c. Notebooks ──────────────────────────────────────────────────────────
    $fabricNotebooks = @(Get-FabricNotebook -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)
    $configNbNames   = @($items?.notebooks | Where-Object { $_ } | Select-Object -ExpandProperty name)

    foreach ($nbConfig in @($items?.notebooks | Where-Object { $_ })) {
        $fabricNb = $fabricNotebooks | Where-Object { $_.displayName -eq $nbConfig.name }
        Add-Check -Category 'Items' -Workspace $wsName -Resource "Notebook:$($nbConfig.name)" `
            -CheckName 'exists' -Status ($fabricNb ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($fabricNb ? 'Exists' : 'NotFound')
        if ($fabricNb) {
            Test-Description -Workspace $wsName -Category 'Items' `
                -Resource "Notebook:$($nbConfig.name)" `
                -Expected $nbConfig.description -Actual $fabricNb.description
        }
    }
    foreach ($fabricNb in $fabricNotebooks) {
        if ($fabricNb.displayName -notin $configNbNames) {
            Add-Warning -Category 'Items' -Workspace $wsName `
                -Resource "Notebook:$($fabricNb.displayName)" `
                -Message "Notebook '$($fabricNb.displayName)' exists in Fabric but is not in config (workspace: $wsName)"
        }
    }

    # ── 3d. Data Pipelines ─────────────────────────────────────────────────────
    $fabricPipelines = @(Get-FabricDataPipeline -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)
    $configPlNames   = @($items?.dataPipelines | Where-Object { $_ } | Select-Object -ExpandProperty name)

    foreach ($plConfig in @($items?.dataPipelines | Where-Object { $_ })) {
        $fabricPl = $fabricPipelines | Where-Object { $_.displayName -eq $plConfig.name }
        Add-Check -Category 'Items' -Workspace $wsName -Resource "Pipeline:$($plConfig.name)" `
            -CheckName 'exists' -Status ($fabricPl ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($fabricPl ? 'Exists' : 'NotFound')
        if ($fabricPl) {
            Test-Description -Workspace $wsName -Category 'Items' `
                -Resource "Pipeline:$($plConfig.name)" `
                -Expected $plConfig.description -Actual $fabricPl.description
        }
    }
    foreach ($fabricPl in $fabricPipelines) {
        if ($fabricPl.displayName -notin $configPlNames) {
            Add-Warning -Category 'Items' -Workspace $wsName `
                -Resource "Pipeline:$($fabricPl.displayName)" `
                -Message "Data pipeline '$($fabricPl.displayName)' exists in Fabric but is not in config (workspace: $wsName)"
        }
    }

    # ── 3e. Spark Environments ─────────────────────────────────────────────────
    $fabricEnvs    = @(Get-FabricEnvironment -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)
    $configEnvNames = @($items?.environments | Where-Object { $_ } | Select-Object -ExpandProperty name)

    foreach ($envConfig in @($items?.environments | Where-Object { $_ })) {
        $fabricEnv = $fabricEnvs | Where-Object { $_.displayName -eq $envConfig.name }
        Add-Check -Category 'Items' -Workspace $wsName -Resource "SparkEnv:$($envConfig.name)" `
            -CheckName 'exists' -Status ($fabricEnv ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($fabricEnv ? 'Exists' : 'NotFound')
        if ($fabricEnv) {
            Test-Description -Workspace $wsName -Category 'Items' `
                -Resource "SparkEnv:$($envConfig.name)" `
                -Expected $envConfig.description -Actual $fabricEnv.description
        }
    }
    foreach ($fabricEnv in $fabricEnvs) {
        if ($fabricEnv.displayName -notin $configEnvNames) {
            Add-Warning -Category 'Items' -Workspace $wsName `
                -Resource "SparkEnv:$($fabricEnv.displayName)" `
                -Message "Spark environment '$($fabricEnv.displayName)' exists in Fabric but is not in config (workspace: $wsName)"
        }
    }

    # ── 3f. Spark Job Definitions ──────────────────────────────────────────────
    $fabricSjds    = @(Get-FabricSparkJobDefinition -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)
    $configSjdNames = @($items?.sparkJobDefinitions | Where-Object { $_ } | Select-Object -ExpandProperty name)

    foreach ($sjdConfig in @($items?.sparkJobDefinitions | Where-Object { $_ })) {
        $fabricSjd = $fabricSjds | Where-Object { $_.displayName -eq $sjdConfig.name }
        Add-Check -Category 'Items' -Workspace $wsName -Resource "SJD:$($sjdConfig.name)" `
            -CheckName 'exists' -Status ($fabricSjd ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($fabricSjd ? 'Exists' : 'NotFound')
        if ($fabricSjd) {
            Test-Description -Workspace $wsName -Category 'Items' `
                -Resource "SJD:$($sjdConfig.name)" `
                -Expected $sjdConfig.description -Actual $fabricSjd.description
        }
    }
    foreach ($fabricSjd in $fabricSjds) {
        if ($fabricSjd.displayName -notin $configSjdNames) {
            Add-Warning -Category 'Items' -Workspace $wsName `
                -Resource "SJD:$($fabricSjd.displayName)" `
                -Message "Spark job definition '$($fabricSjd.displayName)' exists in Fabric but is not in config (workspace: $wsName)"
        }
    }

    # ══════════════════════════════════════════════════════════════════════════
    # CONNECTION CHECKS (workspace-level)
    # ══════════════════════════════════════════════════════════════════════════
    $allFabricConns = Get-FabricConnectionsCache

    foreach ($connConfig in @($wsConfig.connections | Where-Object { $_ })) {
        $match = $allFabricConns | Where-Object { $_.displayName -eq $connConfig.name }
        Add-Check -Category 'Connections' -Workspace $wsName -Resource "Connection:$($connConfig.name)" `
            -CheckName 'exists' -Status ($match ? 'Pass' : 'Fail') `
            -Expected 'Exists' -Actual ($match ? 'Exists' : 'NotFound')
    }

    # ══════════════════════════════════════════════════════════════════════════
    # ROLE ASSIGNMENT CHECKS
    # ══════════════════════════════════════════════════════════════════════════
    $fabricRoles = @(Get-FabricWorkspaceRoleAssignment -WorkspaceId $fabricWs.id -ErrorAction SilentlyContinue)

    foreach ($roleConfig in @($wsConfig.roles | Where-Object { $_ -and (-not $_.remove) })) {
        $principalId = $roleConfig.principal
        $expectedRole = $roleConfig.role

        $found = $fabricRoles | Where-Object {
            ($_.principal?.userPrincipalName -eq $principalId -or
             $_.principal?.id               -eq $principalId) -and
            $_.role -eq $expectedRole
        }

        Add-Check -Category 'Security' -Workspace $wsName `
            -Resource "$expectedRole`:$principalId" `
            -CheckName 'roleAssignment' -Status ($found ? 'Pass' : 'Fail') `
            -Expected "role=$expectedRole,principal=$principalId" `
            -Actual   ($found ? "role=$($found.role),principal=$principalId" : 'NotFound')
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# COMPUTE SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
$totalTime  = ((Get-Date) - $startTime).TotalSeconds
$failCount  = ($checks | Where-Object { $_.status -eq 'Fail' }).Count
$passCount  = ($checks | Where-Object { $_.status -eq 'Pass' }).Count
$hasDrift   = $failCount -gt 0

Write-Host ""
Write-Host "=== Drift Detection Summary ==="
Write-Host "  Checks passed  : $passCount"
Write-Host "  Checks failed  : $failCount"
Write-Host "  Warnings       : $($warnings.Count)"
Write-Host "  Drift detected : $hasDrift"
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# WRITE JSON ARTIFACT
# ══════════════════════════════════════════════════════════════════════════════
$report = [ordered]@{
    environment = $Environment
    timestamp   = (Get-Date -Format 'o')
    hasDrift    = $hasDrift
    summary     = [ordered]@{
        passed   = $passCount
        failed   = $failCount
        warnings = $warnings.Count
    }
    checks   = $checks
    warnings = $warnings
}

$jsonPath = Join-Path $OutputDirectory "drift-report-$Environment.json"
$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host "  JSON report  → $jsonPath"

# ══════════════════════════════════════════════════════════════════════════════
# WRITE NUNIT XML
# ══════════════════════════════════════════════════════════════════════════════
function ConvertTo-XmlSafe ([string]$s) {
    if (-not $s) { return '' }
    [System.Security.SecurityElement]::Escape($s)
}

# Group checks by category for per-suite breakdown
$categories = $checks | Select-Object -ExpandProperty category -Unique

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
$null = $sb.AppendLine("<test-results name=""Fabric Drift Detection"" total=""$($checks.Count)"" errors=""0"" failures=""$failCount"" not-run=""0"" inconclusive=""0"" ignored=""0"" skipped=""0"" invalid=""0"" date=""$(Get-Date -Format 'yyyy-MM-dd')"" time=""$(Get-Date -Format 'HH:mm:ss')"">")
$null = $sb.AppendLine("  <test-suite type=""Assembly"" name=""$Environment"" success=""$($hasDrift ? 'False' : 'True')"" time=""$([math]::Round($totalTime,3))"" asserts=""0"">")
$null = $sb.AppendLine("    <results>")

foreach ($cat in $categories) {
    $catChecks  = @($checks | Where-Object { $_.category -eq $cat })
    $catFails   = ($catChecks | Where-Object { $_.status -eq 'Fail' }).Count
    $catSuccess = ($catFails -eq 0).ToString().ToLower()

    $null = $sb.AppendLine("      <test-suite type=""TestFixture"" name=""$cat"" success=""$catSuccess"" time=""0"" asserts=""0"">")
    $null = $sb.AppendLine("        <results>")

    foreach ($chk in $catChecks) {
        $testName = "[$($chk.workspace)] $($chk.resource) [$($chk.check)]"
        $success  = ($chk.status -eq 'Pass').ToString().ToLower()
        $null = $sb.Append("          <test-case name=""$(ConvertTo-XmlSafe $testName)"" executed=""True"" result=""$($chk.status)"" success=""$success"" time=""0"" asserts=""0"">")
        if ($chk.status -eq 'Fail') {
            $msg = "Expected: $(ConvertTo-XmlSafe $chk.expected) | Actual: $(ConvertTo-XmlSafe $chk.actual)"
            $null = $sb.Append("<failure><message>$msg</message></failure>")
        }
        $null = $sb.AppendLine("</test-case>")
    }

    $null = $sb.AppendLine("        </results>")
    $null = $sb.AppendLine("      </test-suite>")
}

# Append warnings as a separate "informational" suite (all pass so they don't
# fail the job - they appear in ADO Tests for visibility only)
if ($warnings.Count -gt 0) {
    $null = $sb.AppendLine("      <test-suite type=""TestFixture"" name=""Orphaned (Warnings)"" success=""True"" time=""0"" asserts=""0"">")
    $null = $sb.AppendLine("        <results>")
    foreach ($w in $warnings) {
        $testName = "[WARNING] [$($w.workspace)] $($w.resource)"
        $null = $sb.AppendLine("          <test-case name=""$(ConvertTo-XmlSafe $testName)"" executed=""True"" result=""Pass"" success=""true"" time=""0"" asserts=""0""><reason><message>$(ConvertTo-XmlSafe $w.message)</message></reason></test-case>")
    }
    $null = $sb.AppendLine("        </results>")
    $null = $sb.AppendLine("      </test-suite>")
}

$null = $sb.AppendLine("    </results>")
$null = $sb.AppendLine("  </test-suite>")
$null = $sb.AppendLine("</test-results>")

$xmlPath = Join-Path $OutputDirectory "drift-$Environment.xml"
$sb.ToString() | Out-File -FilePath $xmlPath -Encoding UTF8
Write-Host "  NUnit XML    → $xmlPath"

# ── Final ADO annotation ───────────────────────────────────────────────────────
if ($hasDrift) {
    Write-Host "##vso[task.logissue type=error]Drift detected in '$Environment': $failCount check(s) failed. Review the Tests tab and the 'drift-$Environment' artifact."
}

# Always exit 0 - PublishTestResults@2 with failTaskOnFailedTests:true handles
# the ADO job failure based on the NUnit XML content.
exit 0
