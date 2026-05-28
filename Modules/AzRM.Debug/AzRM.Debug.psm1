# ==============================================================================
# AzRM.Debug.psm1
# Debug logging for AzResourceMover.
# Uses a module-scoped variable to store the log path so all other modules
# call Write-Debug* directly without needing to pass the path around.
# Requires: AzRM.Output
# ==============================================================================

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# Module-scoped log path. Empty string means debug is disabled.
$script:DebugLogPath = ""

# ==============================================================================
# INITIALISATION
# ==============================================================================

function Initialize-DebugLog {
<#
.SYNOPSIS
    Creates a timestamped debug log file and activates debug logging.
.DESCRIPTION
    Stores the log path in a module-scoped variable. All subsequent
    Write-Debug* calls write to this file automatically - no path
    parameter required in callers.
    File name format: AzResourceMover_YYYYMMDD_HHmmss.log
.PARAMETER OutputDirectory
    Directory to write the log file. Defaults to the calling script root.
.OUTPUTS
    [string] Full path of the created log file.
#>
    param(
        [string]$OutputDirectory = $PSScriptRoot
    )

    if (-not (Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $timestamp            = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:DebugLogPath  = Join-Path $OutputDirectory "AzResourceMover_$timestamp.log"

    $header = @"
================================================================================
  AzResourceMover Debug Log
  Started  : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Host     : $env:COMPUTERNAME
  User     : $env:USERNAME
  Log File : $script:DebugLogPath
================================================================================

"@
    Set-Content -Path $script:DebugLogPath -Value $header -Encoding UTF8
    Write-Log "Debug log initialised: $script:DebugLogPath" "OK"
    return $script:DebugLogPath
}

function Close-DebugLog {
<#
.SYNOPSIS
    Writes a footer to the debug log and deactivates debug logging.
#>
    if ($script:DebugLogPath -eq "") { return }

    $footer = @"

================================================================================
  Run Completed : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================
"@
    Add-Content -Path $script:DebugLogPath -Value $footer -Encoding UTF8
    Write-Log "Debug log closed: $script:DebugLogPath" "OK"
    $script:DebugLogPath = ""
}

function Get-DebugLogPath {
<#
.SYNOPSIS
    Returns the current debug log file path, or an empty string if not active.
.OUTPUTS
    [string]
#>
    return $script:DebugLogPath
}

function Test-DebugEnabled {
<#
.SYNOPSIS
    Returns $true if debug logging is currently active.
.OUTPUTS
    [bool]
#>
    return ($script:DebugLogPath -ne "")
}

# ==============================================================================
# CORE WRITE HELPER
# ==============================================================================

function Write-DebugLog {
<#
.SYNOPSIS
    Writes a timestamped message to the active debug log file.
.DESCRIPTION
    No-ops silently if debug logging has not been initialised.
    Optionally echoes to the console as a DETAIL entry.
.PARAMETER Message
    The message to write.
.PARAMETER Section
    Optional label prepended to the message (e.g. PREFLIGHT, ANALYSIS).
.PARAMETER EchoToConsole
    When $true, also writes the message to the console as DETAIL.
#>
    param(
        [string]$Message,
        [string]$Section       = "",
        [bool]  $EchoToConsole = $false
    )

    if ($script:DebugLogPath -eq "") { return }

    $ts      = Get-Date -Format "HH:mm:ss"
    $prefix  = if ($Section) { "[$ts][$Section]" } else { "[$ts]" }
    $logLine = "$prefix $Message"

    Add-Content -Path $script:DebugLogPath -Value $logLine -Encoding UTF8

    if ($EchoToConsole) {
        Write-Log $Message "DETAIL"
    }
}

# ==============================================================================
# SECTION MARKER
# ==============================================================================

function Write-DebugSection {
<#
.SYNOPSIS
    Stamps a named pipeline section marker into the debug log.
.PARAMETER Title
    Section title (e.g. "Invoke-MoveValidation", "Get-CrossGroupDependencies").
#>
    param([string]$Title)

    if ($script:DebugLogPath -eq "") { return }

    $block = @"

================================================================================
  $Title
  $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================

"@
    Add-Content -Path $script:DebugLogPath -Value $block -Encoding UTF8
}

# ==============================================================================
# CONTEXT / PREFLIGHT LOGGERS
# ==============================================================================

function Write-DebugContextSwitch {
<#
.SYNOPSIS
    Logs an Azure subscription context switch to the debug file.
.PARAMETER SubscriptionId
    The subscription ID being switched to.
.PARAMETER CalledFrom
    Name of the function initiating the context switch.
#>
    param(
        [string]$SubscriptionId,
        [string]$CalledFrom = ""
    )

    if ($script:DebugLogPath -eq "") { return }

    $caller = if ($CalledFrom) { " (called from: $CalledFrom)" } else { "" }
    Write-DebugLog -Message "Set-AzContext -> SubscriptionId: $SubscriptionId$caller" -Section "CONTEXT"
}

function Write-DebugResourceList {
<#
.SYNOPSIS
    Logs the resolved list of top-level resource IDs to the debug file.
.PARAMETER ResourceIds
    Array of resolved top-level resource IDs.
.PARAMETER Stage
    Label for the pipeline stage (e.g. "After top-level filter").
#>
    param(
        [string[]]$ResourceIds,
        [string]  $Stage = ""
    )

    if ($script:DebugLogPath -eq "") { return }

    Write-DebugSection -Title "Resource List${$(if ($Stage) { ": $Stage" } else { "" })}"
    Write-DebugLog -Message "Count: $($ResourceIds.Count)" -Section "RESOURCES"

    foreach ($id in $ResourceIds) {
        Write-DebugLog -Message "  $id" -Section "RESOURCES"
    }
}

# ==============================================================================
# ARM TEMPLATE LOGGER
# ==============================================================================

function Write-DebugArmExport {
<#
.SYNOPSIS
    Writes the raw exported ARM template JSON to the debug log.
.PARAMETER TemplatePath
    Path to the exported ARM template JSON file.
#>
    param([string]$TemplatePath)

    if ($script:DebugLogPath -eq "") { return }
    if (-not (Test-Path $TemplatePath)) {
        Write-DebugLog -Message "ARM template file not found: $TemplatePath" -Section "ARM"
        return
    }

    Write-DebugSection -Title "ARM Template Export"

    try {
        $raw    = Get-Content $TemplatePath -Raw
        $pretty = $raw | ConvertFrom-Json | ConvertTo-Json -Depth 20
        Add-Content -Path $script:DebugLogPath -Value $pretty -Encoding UTF8
    }
    catch {
        Add-Content -Path $script:DebugLogPath -Value "(could not parse ARM template: $($_.Exception.Message))" -Encoding UTF8
    }
}

# ==============================================================================
# HTTP REQUEST / RESPONSE LOGGERS
# ==============================================================================

function Write-DebugRequest {
<#
.SYNOPSIS
    Logs the full HTTP request payload sent to the Azure REST API.
.PARAMETER ApiPath
    The REST API path being called.
.PARAMETER Method
    HTTP method (e.g. POST).
.PARAMETER Body
    The raw JSON body string sent with the request.
#>
    param(
        [string]$ApiPath,
        [string]$Method,
        [string]$Body
    )

    if ($script:DebugLogPath -eq "") { return }

    try   { $prettyBody = $Body | ConvertFrom-Json | ConvertTo-Json -Depth 10 }
    catch { $prettyBody = $Body }

    $divider = "-" * 80
    $block   = @"
$divider
REQUEST
$divider
Timestamp : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Method    : $Method
Path      : $ApiPath

--- Body ---
$prettyBody
$divider

"@
    Add-Content -Path $script:DebugLogPath -Value $block -Encoding UTF8
    Write-Log "Debug: request payload written to log." "DETAIL"
}

function Write-DebugResponse {
<#
.SYNOPSIS
    Logs the full HTTP response received from the Azure REST API.
.PARAMETER StatusCode
    The HTTP status code returned.
.PARAMETER Headers
    The response headers (hashtable or ordered dictionary). Optional.
.PARAMETER Content
    The raw response body string.
#>
    param(
        [int]   $StatusCode,
        [object]$Headers = $null,
        [string]$Content = ""
    )

    if ($script:DebugLogPath -eq "") { return }

    $prettyContent = if ($Content) {
        try   { $Content | ConvertFrom-Json | ConvertTo-Json -Depth 10 }
        catch { $Content }
    } else { "(empty)" }

    $headerLines = if ($Headers) {
        ($Headers | ForEach-Object { "$($_.Key): $(@($_.Value) -join ', ')" }) -join "`n"
    } else { "(none)" }

    $divider = "-" * 80
    $block   = @"
$divider
RESPONSE
$divider
Timestamp   : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Status Code : $StatusCode

--- Headers ---
$headerLines

--- Body ---
$prettyContent
$divider

"@
    Add-Content -Path $script:DebugLogPath -Value $block -Encoding UTF8
    Write-Log "Debug: response payload written to log." "DETAIL"
}

Export-ModuleMember -Function @(
    'Initialize-DebugLog',
    'Close-DebugLog',
    'Get-DebugLogPath',
    'Test-DebugEnabled',
    'Write-DebugLog',
    'Write-DebugSection',
    'Write-DebugContextSwitch',
    'Write-DebugResourceList',
    'Write-DebugArmExport',
    'Write-DebugRequest',
    'Write-DebugResponse'
)
