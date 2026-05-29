#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently connects Fabric workspaces to Git repositories and performs
    initial synchronization.

.DESCRIPTION
    For each workspace with a 'gitIntegration' block in the environment config:
      1. Gets current Git connection state via GET .../git/connection
      2. If not connected → connects to the configured provider/repo/branch/directory
      3. Initializes the connection using the configured initializationStrategy
      4. Follows the requiredAction returned by initialize:
           None          → done, already in sync
           UpdateFromGit → pulls remote branch into workspace
           CommitToGit   → pushes workspace items to remote branch

    Also supports explicit disconnect when gitIntegration: false.

    Idempotency:
      - If the workspace is already ConnectedAndInitialized to the correct
        repo/branch/directory, the connect + init steps are skipped.
      - If the connection details differ, the workspace is disconnected and
        reconnected.
      - Long-running operations (LRO) are polled via Wait-FabLongRunningOperation.

    Supports Azure DevOps and GitHub providers. Use 'ConfiguredConnection'
    credentials (connectionId) for service principal / managed identity auth.
    Automatic credentials are not supported for GitHub or SPN/MI.

    Called by Deploy-FabricEnvironment.ps1 after workspaces are provisioned.
    Assumes 'fab auth login' has already been called in the same shell session.

.PARAMETER Config
    Validated PSCustomObject from Read-EnvironmentConfig.

.PARAMETER WorkspaceMap
    Hashtable of workspace name → workspace GUID produced by Deploy-Workspaces.ps1.

.PARAMETER Environment
    Target environment (dev | tst | prd). Used in commit comments.

.EXAMPLE
    .\Deploy-GitIntegration.ps1 `
        -Config       $config `
        -WorkspaceMap $workspaceMap `
        -Environment  'dev'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

# ── Helper: unwrap the fab api JSON envelope ──────────────────────────────────
# fab api with JSON output wraps responses in:
#   { result: { data: [{ status_code: int, text: <actual body> }] } }
# This function extracts the actual API response body from the envelope.
function Get-FabApiBody {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] $FabOutput)

    if ($null -eq $FabOutput) { return $null }

    # Navigate into the envelope if present
    if ($FabOutput.PSObject.Properties.Name -contains 'result' -and
        $FabOutput.result.PSObject.Properties.Name -contains 'data' -and
        $FabOutput.result.data.Count -gt 0) {
        $text = $FabOutput.result.data[0].text
        # fab returns string "(Empty)" for empty response bodies
        if ($text -is [string] -and $text -eq '(Empty)') { return $null }
        return $text
    }

    # No envelope — return as-is (e.g. non-JSON or unexpected format)
    return $FabOutput
}

# ── Helper: invoke a Git API call and handle LRO responses ────────────────────
function Invoke-GitApiWithLro {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]   $Endpoint,
        [Parameter(Mandatory)] [string]   $Method,        # get | post | patch
        [string]               $Payload = '',
        [string]               $OpDesc = 'Git API call',
        [int]                  $MaxRetries = 2,
        [int]                  $LroMaxWaitSeconds = 300
    )

    $fabArgs = @('api', '-X', $Method, $Endpoint)
    if ($Payload) { $fabArgs += @('-i', $Payload) }

    $result = Invoke-FabCli -Arguments $fabArgs -MaxRetries $MaxRetries -AllowNonZeroExit -JsonOutput

    # The fab api command may transparently handle LRO polling already.
    # If it returns an operationId in the response, we poll explicitly.
    if ($result.ExitCode -ne 0) {
        $errMsg = "$OpDesc failed (exit $($result.ExitCode))"
        if ($result.Stderr) { $errMsg += ": $($result.Stderr)" }
        elseif ($result.Output) { $errMsg += ": $($result.Output)" }
        throw $errMsg
    }

    # Unwrap the fab api response envelope to get the actual API body
    $body = Get-FabApiBody -FabOutput $result.Output

    # Check if response body contains an LRO operation ID
    if ($body -and $body -is [PSCustomObject] -and
        ($body.PSObject.Properties.Name -contains 'operationId' -or
        $body.PSObject.Properties.Name -contains 'id')) {
        $opId = if ($body.operationId) { $body.operationId }
        elseif ($body.id -and $body.PSObject.Properties.Name -contains 'status') { $body.id }
        else { $null }

        if ($opId -and $body.PSObject.Properties.Name -contains 'status' -and
            $body.status -in @('Running', 'NotStarted')) {
            Write-Verbose "  $OpDesc returned LRO (operationId: $opId). Polling for completion..."
            return Wait-FabLongRunningOperation -OperationId $opId -MaxWaitSeconds $LroMaxWaitSeconds
        }
    }

    return $body
}

# ── Helper: compare current provider details to desired ───────────────────────
function Test-ProviderMatch {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Current,
        [Parameter(Mandatory)] [hashtable]      $Desired
    )

    if ($Current.gitProviderType -ne $Desired.gitProviderType) { return $false }
    if ($Current.repositoryName -ne $Desired.repositoryName) { return $false }
    if ($Current.branchName -ne $Desired.branchName) { return $false }

    $curDir = if ($null -ne $Current.directoryName) { $Current.directoryName.TrimStart('/') } else { '' }
    $desDir = if ($Desired.ContainsKey('directoryName') -and $Desired.directoryName) { $Desired.directoryName.TrimStart('/') } else { '' }
    if ($curDir -ne $desDir) { return $false }

    if ($Desired.gitProviderType -eq 'AzureDevOps') {
        if ($Current.organizationName -ne $Desired.organizationName) { return $false }
        if ($Current.projectName -ne $Desired.projectName) { return $false }
    }
    elseif ($Desired.gitProviderType -eq 'GitHub') {
        if ($Current.ownerName -ne $Desired.ownerName) { return $false }
    }

    return $true
}

# ── Helper: ensure directory exists in Azure DevOps repo ─────────────────────
# Fabric's Git connect API returns GitProviderResourceNotFound if the directory
# does not exist in the repo. This function creates a .gitkeep placeholder file
# to ensure the directory exists on the target branch before connecting.
# Uses the Azure DevOps REST API with the pipeline's System.AccessToken.
function Initialize-AdoGitDirectory {
    param(
        [string]$Organization,
        [string]$Project,
        [string]$Repository,
        [string]$Branch,
        [string]$DirectoryName,
        [string]$AccessToken,
        [int]$PrAutoCompleteTimeoutSeconds = 120
    )

    $baseUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$Repository"
    $apiVer = 'api-version=7.1'
    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }

    # ── 1. Check if the directory already exists ─────────────────────────────
    $itemUri = "$baseUri/items?path=/$DirectoryName/.gitkeep&versionDescriptor.version=$Branch&$apiVer"
    try {
        $null = Invoke-RestMethod -Uri $itemUri -Headers $headers -Method Get -ErrorAction Stop
        Write-Host "    Directory '$DirectoryName' already exists in branch '$Branch'. Skipping."
        return
    }
    catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -ne 404) {
            Write-Warning "    Unexpected error checking directory existence (HTTP $sc): $_"
        }
        # 404 → doesn't exist yet, proceed
    }

    # ── 2. Resolve latest commit on target branch ─────────────────────────────
    $refUri = "$baseUri/refs?filter=heads/$Branch&$apiVer"
    $refs = Invoke-RestMethod -Uri $refUri -Headers $headers -Method Get -ErrorAction Stop
    $refObj = $refs.value | Where-Object { $_.name -eq "refs/heads/$Branch" }
    if (-not $refObj) {
        throw "Branch '$Branch' not found in repository '$Repository'."
    }
    $latestCommit = $refObj.objectId

    # ── 3. Build the commit payload (reused for direct push and PR branch) ────
    function New-GitkeepPushPayload {
        param([string]$RefName, [string]$OldObjectId)
        @{
            refUpdates = @(@{ name = $RefName; oldObjectId = $OldObjectId })
            commits    = @(@{
                    comment = "chore: create $DirectoryName directory for Fabric workspace [fabric-cicd-v2]"
                    changes = @(@{
                            changeType = 'add'
                            item       = @{ path = "/$DirectoryName/.gitkeep" }
                            newContent = @{ content = ''; contentType = 'rawtext' }
                        })
                })
        }
    }

    $pushUri = "$baseUri/pushes?$apiVer"

    # ── 4. Attempt direct push ────────────────────────────────────────────────
    $directPayload = New-GitkeepPushPayload `
        -RefName     "refs/heads/$Branch" `
        -OldObjectId $latestCommit

    try {
        $null = Invoke-RestMethod -Uri $pushUri -Headers $headers -Method Post `
            -Body ($directPayload | ConvertTo-Json -Depth 10) -ErrorAction Stop
        Write-Host "    Directory '$DirectoryName' created in '$Branch' via direct push."
        return
    }
    catch {
        $sc = $_.Exception.Response.StatusCode.value__
        $errMsg = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).message
        $errMsg ??= $_.Exception.Message

        # TF402455 / "pull request" / 403 = branch policy blocks direct push
        $isPolicyBlock = ($sc -eq 403) -or
        ($errMsg -match 'pull request') -or
        ($errMsg -match 'TF402455')

        if (-not $isPolicyBlock) {
            throw "Unexpected error pushing to '$Branch' (HTTP $sc): $errMsg"
        }

        Write-Host "    Direct push to '$Branch' blocked by branch policy (HTTP $sc)."
        Write-Host "    Falling back to pull-request approach..."
    }

    # ── 5. Create temp branch AND commit .gitkeep in one push ────────────────
    # The pushes API creates the branch automatically when oldObjectId is all-zeros.
    # No separate refs call needed.
    $safeDirName = $DirectoryName -replace '[^a-zA-Z0-9_\-.]', '-'
    $tempBranch = "fabric-cicd/init-$safeDirName-$(Get-Date -Format 'yyyyMMddHHmmss')"

    $tempPayload = New-GitkeepPushPayload `
        -RefName     "refs/heads/$tempBranch" `
        -OldObjectId '0000000000000000000000000000000000000000'

    $null = Invoke-RestMethod -Uri $pushUri -Headers $headers -Method Post `
        -Body ($tempPayload | ConvertTo-Json -Depth 10) -ErrorAction Stop
    Write-Host "    Temp branch '$tempBranch' created with .gitkeep commit."

    # ── 6. Open a pull request ────────────────────────────────────────────────
    $prPayload = @{
        title         = "chore: create $DirectoryName for Fabric workspace [fabric-cicd-v2]"
        description   = "Auto-created by fabric-cicd-v2 to satisfy Fabric Git integration directory requirement. Safe to merge."
        sourceRefName = "refs/heads/$tempBranch"
        targetRefName = "refs/heads/$Branch"
    }
    $pr = Invoke-RestMethod -Uri "$baseUri/pullrequests?$apiVer" -Headers $headers -Method Post `
        -Body ($prPayload | ConvertTo-Json -Depth 5) -ErrorAction Stop
    $prId = $pr.pullRequestId
    Write-Host "    PR #$prId created: $($pr.url)"

    # ── 7. Set auto-complete (merges once required policies pass) ─────────────
    $autoCompletePayload = @{
        autoCompleteSetBy = @{ id = $pr.createdBy.id }
        completionOptions = @{
            deleteSourceBranch = $true
            mergeStrategy      = 'squash'
            bypassPolicy       = $false
            bypassReason       = ''
        }
    }
    $null = Invoke-RestMethod -Uri "$baseUri/pullrequests/$($prId)?$apiVer" `
        -Headers $headers -Method Patch `
        -Body ($autoCompletePayload | ConvertTo-Json -Depth 5) -ErrorAction Stop
    Write-Host "    Auto-complete enabled on PR #$prId (merges once policies pass, squash, deletes source branch)."

    # ── 8. Poll until merged or timed out ─────────────────────────────────────
    $deadline = (Get-Date).AddSeconds($PrAutoCompleteTimeoutSeconds)
    $prUri = "$baseUri/pullrequests/$($prId)?$apiVer"

    Write-Host "    Waiting up to ${PrAutoCompleteTimeoutSeconds}s for PR #$prId to complete..."
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $prStatus = Invoke-RestMethod -Uri $prUri -Headers $headers -Method Get -ErrorAction Stop
        switch ($prStatus.status) {
            'completed' {
                Write-Host "    PR #$prId merged. Directory '$DirectoryName' is ready in '$Branch'."
                return
            }
            'abandoned' {
                throw "PR #$prId was abandoned. Directory '$DirectoryName' was not created in '$Branch'."
            }
        }
        Write-Host "    PR #$prId status: $($prStatus.status) — waiting..."
    }

    # ── 9. Timeout: warn and let the Fabric connect step surface the failure ──
    Write-Warning @"
    ⚠ PR #$prId has not merged within ${PrAutoCompleteTimeoutSeconds}s.
      This usually means required reviewers or additional policy checks are pending.
      Options:
        (a) Approve and complete PR #$prId manually, then re-run the pipeline.
        (b) Pre-create the '$DirectoryName' directory in '$Branch' yourself.
        (c) Increase -PrAutoCompleteTimeoutSeconds if policies take longer (e.g. slow CI checks).
"@
}

# ── Process each workspace ────────────────────────────────────────────────────
$processedCount = 0

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    $hasGit = $workspaceConfig.PSObject.Properties.Name -contains 'gitIntegration'
    if (-not $hasGit) {
        Write-Verbose "  No gitIntegration config for: $wsName. Skipping."
        continue
    }

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  Workspace '$wsName' not in workspace map. Skipping Git integration."
        continue
    }

    $wsId = $WorkspaceMap[$wsName]
    $gitConfig = $workspaceConfig.gitIntegration
    $connBase = "workspaces/$wsId/git"

    Write-Host ""
    Write-Host "  [$wsName] Processing Git integration..."

    # ── Get current connection ────────────────────────────────────────────────
    $connResult = Invoke-FabCli -Arguments @(
        'api', "$connBase/connection"
    ) -MaxRetries 2 -JsonOutput
    $conn = Get-FabApiBody -FabOutput $connResult.Output
    $state = if ($conn -and $conn -is [PSCustomObject] -and
        $conn.PSObject.Properties.Name -contains 'gitConnectionState') {
        $conn.gitConnectionState
    }
    else { 'NotConnected' }

    Write-Verbose "  [$wsName] Current state: $state"

    # ── Handle explicit disconnect ────────────────────────────────────────────
    if ($gitConfig -eq $false) {
        if ($state -ne 'NotConnected') {
            Write-Host "    Disconnecting workspace from Git..."
            Invoke-FabCli -Arguments @('api', '-X', 'post', "$connBase/disconnect") -MaxRetries 1 | Out-Null
            Write-Host "    Disconnected."
        }
        else {
            Write-Host "    Already disconnected. Nothing to do."
        }
        $processedCount++
        continue
    }

    # ── Build desired provider details ────────────────────────────────────────
    $desiredProvider = @{
        gitProviderType = $gitConfig.provider
        repositoryName  = $gitConfig.repositoryName
        branchName      = $gitConfig.branchName
        directoryName   = if ($gitConfig.PSObject.Properties.Name -contains 'directoryName' -and $gitConfig.directoryName) {
            $gitConfig.directoryName
        }
        else { '' }
    }

    if ($gitConfig.provider -eq 'AzureDevOps') {
        $desiredProvider['organizationName'] = $gitConfig.organizationName
        $desiredProvider['projectName'] = $gitConfig.projectName
    }
    elseif ($gitConfig.provider -eq 'GitHub') {
        $desiredProvider['ownerName'] = $gitConfig.ownerName
    }

    # ── Determine required actions ────────────────────────────────────────────
    $needsConnect = $false
    $needsDisconnect = $false
    $needsInit = $false

    switch ($state) {
        'NotConnected' {
            $needsConnect = $true
            $needsInit = $true
        }
        'Connected' {
            # Connected but not yet initialized
            $needsInit = $true
        }
        { $_ -in @('ConnectedAndInitialized', 'PartiallyConnected') } {
            if ($conn.gitProviderDetails -and
                (Test-ProviderMatch -Current $conn.gitProviderDetails -Desired $desiredProvider)) {
                Write-Host "    Git connection already matches desired config. Skipping connect + init."
            }
            else {
                Write-Host "    Git connection differs from desired. Reconnecting..."
                $needsDisconnect = $true
                $needsConnect = $true
                $needsInit = $true
            }
        }
        default {
            Write-Warning "    Unknown Git connection state '$state'. Attempting reconnect."
            $needsDisconnect = $true
            $needsConnect = $true
            $needsInit = $true
        }
    }

    # ── Disconnect ────────────────────────────────────────────────────────────
    if ($needsDisconnect) {
        Write-Host "    Disconnecting existing Git connection..."
        Invoke-FabCli -Arguments @('api', '-X', 'post', "$connBase/disconnect") -MaxRetries 1 | Out-Null
        Write-Host "    Disconnected."
    }

    # ── Connect ───────────────────────────────────────────────────────────────
    if ($needsConnect) {
        $connectPayload = @{ gitProviderDetails = $desiredProvider }

        $hasConnId = ($gitConfig.PSObject.Properties.Name -contains 'connectionId') -and $gitConfig.connectionId
        if ($hasConnId) {
            $connectPayload['myGitCredentials'] = @{
                source       = 'ConfiguredConnection'
                connectionId = $gitConfig.connectionId
            }
        }

        # ── Ensure directory exists in repo (Fabric requires it to exist) ───────
        if ($gitConfig.provider -eq 'AzureDevOps' -and $desiredProvider.directoryName) {
            $adoToken = $env:SYSTEM_ACCESSTOKEN
            if (-not $adoToken) {
                Write-Warning "    SYSTEM_ACCESSTOKEN not available. Skipping auto-creation of repo directory."
                Write-Warning "    Set env: SYSTEM_ACCESSTOKEN: `$(System.AccessToken) in your pipeline YAML."
            }
            else {
                Write-Host "    Ensuring directory '$($desiredProvider.directoryName)' exists in repo..."
                Initialize-AdoGitDirectory `
                    -Organization  $gitConfig.organizationName `
                    -Project       $gitConfig.projectName `
                    -Repository    $gitConfig.repositoryName `
                    -Branch        $gitConfig.branchName `
                    -DirectoryName $desiredProvider.directoryName `
                    -AccessToken   $adoToken
            }
        }

        $connectJson = $connectPayload | ConvertTo-Json -Depth 5 -Compress
        Write-Host "    Connecting to $($gitConfig.provider): $($gitConfig.repositoryName) / $($gitConfig.branchName)"

        $connectResult = Invoke-FabCli -Arguments @(
            'api', '-X', 'post', "$connBase/connect", '-i', "'$connectJson'"
        ) -MaxRetries 1

        Write-Host "    Connect response (exit $($connectResult.ExitCode)): $($connectResult.Output | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)"
        if ($connectResult.Stderr) { Write-Host "    Connect stderr: $($connectResult.Stderr)" }

        Write-Host "    Waiting 15s for Fabric to propagate connection..."
        Start-Sleep -Seconds 15

        # Verify connection was actually established (poll — Fabric API may take a few seconds to propagate)
        $verifyState = 'Unknown'
        $maxVerifyPolls = 5
        $pollDelaySec = 10
        for ($poll = 1; $poll -le $maxVerifyPolls; $poll++) {
            $verifyResult = Invoke-FabCli -Arguments @(
                'api', "$connBase/connection"
            ) -MaxRetries 2 -JsonOutput
            $verifyConn = Get-FabApiBody -FabOutput $verifyResult.Output
            $verifyState = if ($verifyConn -and $verifyConn -is [PSCustomObject] -and
                $verifyConn.PSObject.Properties.Name -contains 'gitConnectionState') {
                $verifyConn.gitConnectionState
            }
            else { 'Unknown' }

            if ($verifyState -notin @('NotConnected', 'Unknown')) { break }

            if ($poll -lt $maxVerifyPolls) {
                Write-Verbose "    Connection state still '$verifyState' (poll $poll/$maxVerifyPolls). Waiting ${pollDelaySec}s..."
                Start-Sleep -Seconds $pollDelaySec
            }
        }

        if ($verifyState -in @('NotConnected', 'Unknown')) {
            Write-Verbose "    Verify response: $($verifyResult.Output | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)"
            throw "Git connect for $wsName failed. Post-connect state: $verifyState (after $maxVerifyPolls polls)."
        }
        Write-Host "    Connected (state: $verifyState)."
    }

    # ── Initialize connection ─────────────────────────────────────────────────
    if ($needsInit) {
        $strategy = if ($gitConfig.PSObject.Properties.Name -contains 'initializationStrategy' -and
            $gitConfig.initializationStrategy) {
            $gitConfig.initializationStrategy
        }
        else { 'PreferRemote' }

        $initJson = (@{ initializationStrategy = $strategy } | ConvertTo-Json -Compress)
        Write-Host "    Initializing connection (strategy: $strategy)..."

        $initResponse = Invoke-GitApiWithLro `
            -Endpoint  "$connBase/initializeConnection" `
            -Method    'post' `
            -Payload   $initJson `
            -OpDesc    "initializeConnection for $wsName"

        $requiredAction = if ($initResponse -and $initResponse.PSObject.Properties.Name -contains 'requiredAction') {
            $initResponse.requiredAction
        }
        else { 'None' }

        Write-Host "    Required action: $requiredAction"

        # ── Execute required sync action ──────────────────────────────────────
        switch ($requiredAction) {
            'None' {
                Write-Host "    Workspace is in sync. No further action required."
            }

            'UpdateFromGit' {
                $conflictPolicy = if ($gitConfig.PSObject.Properties.Name -contains 'conflictResolutionPolicy' -and
                    $gitConfig.conflictResolutionPolicy) {
                    $gitConfig.conflictResolutionPolicy
                }
                else { 'PreferRemote' }

                $allowOverride = if ($gitConfig.PSObject.Properties.Name -contains 'allowOverrideItems') {
                    [bool]$gitConfig.allowOverrideItems
                }
                else { $true }

                $updatePayload = @{
                    remoteCommitHash   = $initResponse.remoteCommitHash
                    conflictResolution = @{
                        conflictResolutionType   = 'Workspace'
                        conflictResolutionPolicy = $conflictPolicy
                    }
                    options            = @{
                        allowOverrideItems = $allowOverride
                    }
                }
                if ($initResponse.workspaceHead) {
                    $updatePayload['workspaceHead'] = $initResponse.workspaceHead
                }

                $updateJson = $updatePayload | ConvertTo-Json -Depth 5 -Compress
                Write-Host "    Updating workspace from Git (conflictPolicy: $conflictPolicy, allowOverride: $allowOverride)..."

                Invoke-GitApiWithLro `
                    -Endpoint "$connBase/updateFromGit" `
                    -Method   'post' `
                    -Payload  $updateJson `
                    -OpDesc   "updateFromGit for $wsName" | Out-Null

                Write-Host "    Update from Git complete."
            }

            'CommitToGit' {
                $commitPayload = @{
                    mode          = 'All'
                    workspaceHead = $initResponse.workspaceHead
                    comment       = "Initial commit from fabric-cicd-v2 [$Environment]"
                } | ConvertTo-Json -Depth 5 -Compress

                Write-Host "    Committing workspace to Git..."

                Invoke-GitApiWithLro `
                    -Endpoint "$connBase/commitToGit" `
                    -Method   'post' `
                    -Payload  $commitPayload `
                    -OpDesc   "commitToGit for $wsName" | Out-Null

                Write-Host "    Commit to Git complete."
            }

            default {
                Write-Warning "    Unrecognised requiredAction '$requiredAction'. Skipping sync."
            }
        }
    }

    $processedCount++
}

Write-Host ""
Write-Host "  Git integration complete. Workspaces processed: $processedCount"