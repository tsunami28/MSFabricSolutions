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
      2  = Authentication error (not retried — requires re-auth)
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
      ExitCode  [int]    — fab process exit code
      Output    [object] — parsed JSON (when --output_format json) or raw stdout string
      Stderr    [string] — stderr content (populated on errors)

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

        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()

        try {
            $proc = Start-Process `
                -FilePath        'fab' `
                -ArgumentList    $Arguments `
                -Wait `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError  $stderrFile

            $stdout = (Get-Content -Path $stdoutFile -Raw -ErrorAction SilentlyContinue) ?? ''
            $stderr = (Get-Content -Path $stderrFile -Raw -ErrorAction SilentlyContinue) ?? ''
        } finally {
            Remove-Item -Path $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        }

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
        } elseif ($lastResult.Output) {
            $errMsg += "`n  output: $($lastResult.Output)"
        }

        if ($lastResult.ExitCode -eq $script:FabExitCode_AuthError) {
            $errMsg = "Authentication error — $errMsg. Run 'fab auth login' and try again."
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

    $result = Invoke-FabCli @('exists', $Path) -AllowNonZeroExit -MaxRetries 0
    return $result.ExitCode -eq $script:FabExitCode_Success
}
