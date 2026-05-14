#Requires -Version 7.0

<#
.SYNOPSIS
    Wrapper for executing Fabric CLI (fab) commands from PowerShell.

.DESCRIPTION
    Provides Invoke-FabCli as a consistent, testable wrapper around the
    ms-fabric-cli 'fab' binary with:
      - Stdout/stderr capture via temp files
      - Automatic JSON parsing when --output_format json is present in arguments
      - Structured error messages with stderr context
      - Exponential backoff retry for transient failures (configurable)
      - Verbose logging of every command invocation

    Exit code handling:
      0  = Success
      1  = General error (retried if -MaxRetries > 0)
      2  = Authentication error (not retried - requires re-auth)
      3+ = Other errors (retried)

    Callers that need to test existence (fab exists) should pass -AllowNonZeroExit
    and inspect the returned exit code directly.

.NOTES
    Dot-sourced by all deployment scripts. Not a standalone script.
    Requires 'fab' (ms-fabric-cli) to be in PATH.
#>

# ── Constants ──────────────────────────────────────────────────────────────────
$script:FabExitCode_Success   = 0
$script:FabExitCode_AuthError = 2

# =============================================================================
function Invoke-FabCli {
<#
.SYNOPSIS
    Executes a Fabric CLI command and returns the parsed or raw output.

.PARAMETER Arguments
    Array of arguments to pass to 'fab'. Do not include 'fab' itself.
    Example: @('ls', 'MyWorkspace.Workspace', '--output_format', 'json')

.PARAMETER MaxRetries
    Number of retry attempts for non-auth failures. Default: 3.

.PARAMETER RetryBackoffBase
    Base seconds for exponential backoff. Delay = RetryBackoffBase ^ attempt.
    Default: 2 (delays: 2s, 4s, 8s).

.PARAMETER AllowNonZeroExit
    When set, a non-zero exit code does NOT throw. Returns a result object with
    ExitCode populated. Use for 'fab exists' which returns 1 when not found.

.OUTPUTS
    [PSCustomObject] with properties:
      ExitCode  [int]    - fab process exit code
      Output    [object] - parsed JSON (when --output_format json) or raw stdout string
      Stderr    [string] - stderr content (populated on errors)

.EXAMPLE
    # List all workspaces as JSON
    $result = Invoke-FabCli @('ls', '--output_format', 'json')
    $result.Output   # already parsed PSCustomObject / array

.EXAMPLE
    # Check if a workspace exists
    $result = Invoke-FabCli @('exists', 'MyWorkspace.Workspace') -AllowNonZeroExit
    $exists = $result.ExitCode -eq 0

.EXAMPLE
    # Create a workspace (retry on transient failure)
    Invoke-FabCli @('mkdir', 'MyWorkspace.Workspace', '-P', 'capacityname=MyCap') -MaxRetries 3
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [int]$MaxRetries = 3,

        [Parameter()]
        [int]$RetryBackoffBase = 2,

        [Parameter()]
        [switch]$AllowNonZeroExit
    )

    $isJsonOutput = ($Arguments -contains '--output_format') -and
                    ($Arguments[$Arguments.IndexOf('--output_format') + 1] -eq 'json')

    $cmdDisplay = "fab $($Arguments -join ' ')"
    Write-Verbose "fab: $cmdDisplay"
    Write-Information "[fab] $cmdDisplay" -InformationAction Continue

    $attempt  = 0
    $lastResult = $null

    do {
        if ($attempt -gt 0) {
            $delaySec = [Math]::Pow($RetryBackoffBase, $attempt)
            Write-Warning "fab command failed (exit $($lastResult.ExitCode)). Retrying in $delaySec s... (attempt $($attempt + 1) of $MaxRetries)"
            Start-Sleep -Seconds $delaySec
        }

        # Use System.Diagnostics.Process with ArgumentList (not Arguments).
        # ArgumentList passes each entry as a separate argv element via execvp
        # without any string parsing, so characters like " in JSON payloads are
        # preserved exactly. Start-Process and ProcessStartInfo.Arguments both
        # join into a single string that .NET re-splits on Unix, mangling quotes.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = 'fab'
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi

        $proc.Start() | Out-Null

        # Read stderr asynchronously via .NET Task to avoid deadlocks.
        # (PowerShell script-block event handlers crash on threadpool threads
        #  because no Runspace is available — use ReadToEndAsync instead.)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdout     = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $stderr     = $stderrTask.GetAwaiter().GetResult()

        $stdout = $stdout.Trim()
        $stderr = $stderr.Trim()

        $lastResult = [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Output   = $stdout
            Stderr   = $stderr
        }

        # Auth errors are not retriable
        if ($proc.ExitCode -eq $script:FabExitCode_AuthError) {
            break
        }

        $attempt++

    } while ($proc.ExitCode -ne $script:FabExitCode_Success -and $attempt -le $MaxRetries)

    # ── Parse JSON output ──────────────────────────────────────────────────────
    if ($isJsonOutput -and $lastResult.Output) {
        try {
            $lastResult.Output = $lastResult.Output | ConvertFrom-Json -Depth 20
        } catch {
            Write-Warning "fab returned non-JSON output despite --output_format json. Raw output preserved."
        }
    }

    # ── Handle failures ────────────────────────────────────────────────────────
    if ($lastResult.ExitCode -ne $script:FabExitCode_Success -and -not $AllowNonZeroExit) {
        $errMsg = "fab command failed (exit $($lastResult.ExitCode)): $cmdDisplay"
        if ($lastResult.Stderr) {
            $errMsg += "`n  stderr: $($lastResult.Stderr)"
        }
        if ($lastResult.Output) {
            $errMsg += "`n  output: $($lastResult.Output)"
        }

        if ($lastResult.ExitCode -eq $script:FabExitCode_AuthError) {
            $errMsg = "Authentication error - $errMsg. Run 'fab auth login' and try again."
        }

        throw $errMsg
    }

    return $lastResult
}

# =============================================================================
function Test-FabResourceExists {
<#
.SYNOPSIS
    Returns $true if a Fabric resource path exists, $false otherwise.

.PARAMETER Path
    Fabric CLI path (e.g. 'MyWorkspace.Workspace' or
    'MyWorkspace.Workspace/MyLakehouse.Lakehouse').

.EXAMPLE
    if (Test-FabResourceExists 'Analytics-Dev.Workspace') { ... }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Newer fab versions can return exit code 0 for both true/false and put
    # the existence result in stdout. Evaluate both exit code and output.
    $result = Invoke-FabCli -Arguments @('exists', $Path) -AllowNonZeroExit -MaxRetries 0

    if ($result.ExitCode -ne $script:FabExitCode_Success) {
        return $false
    }

    if ($result.Output -is [bool]) {
        return $result.Output
    }

    $text = [string]$result.Output
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    switch ($text.Trim().Trim('"').ToLowerInvariant()) {
        'true'  { return $true }
        'false' { return $false }
        default { return $false }
    }
}

# =============================================================================
function Wait-FabLongRunningOperation {
<#
.SYNOPSIS
    Polls a Fabric long-running operation until it completes or times out.

.DESCRIPTION
    Several Fabric API calls (Git Initialize Connection, Update From Git,
    Commit To Git, Get Status) can return 202 Accepted with an operation ID.
    This function polls GET /v1/operations/{operationId} until the operation
    status is 'Succeeded' or 'Failed', or until MaxWaitSeconds is exceeded.

.PARAMETER OperationId
    The Fabric operation ID returned in the x-ms-operation-id response header
    or the 'id' field of the LRO response body.

.PARAMETER MaxWaitSeconds
    Maximum total seconds to wait before throwing a timeout error. Default: 300.

.PARAMETER RetryAfterSeconds
    Polling interval in seconds. Default: 10.

.OUTPUTS
    [PSCustomObject] — the final operation status response body.

.EXAMPLE
    $status = Wait-FabLongRunningOperation -OperationId $opId
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [Parameter()]
        [int]$MaxWaitSeconds = 300,

        [Parameter()]
        [int]$RetryAfterSeconds = 10
    )

    $elapsed = 0
    Write-Verbose "  Polling LRO: $OperationId"

    while ($elapsed -lt $MaxWaitSeconds) {
        Start-Sleep -Seconds $RetryAfterSeconds
        $elapsed += $RetryAfterSeconds

        $statusResult = Invoke-FabCli -Arguments @(
            'api', "operations/$OperationId", '--output_format', 'json'
        ) -MaxRetries 2

        $status = $statusResult.Output

        switch ($status.status) {
            'Succeeded' {
                Write-Verbose "  LRO $OperationId succeeded after ${elapsed}s."
                return $status
            }
            'Failed' {
                $errMsg = if ($status.error) { "$($status.error.errorCode): $($status.error.message)" } else { 'unknown error' }
                throw "LRO $OperationId failed: $errMsg"
            }
            default {
                Write-Verbose "  LRO $OperationId status: $($status.status) (${elapsed}s elapsed)..."
            }
        }
    }

    throw "LRO $OperationId timed out after $MaxWaitSeconds seconds."
}
