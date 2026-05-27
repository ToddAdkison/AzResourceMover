# ==============================================================================
# AzRM.Output.psm1
# Shared console output helpers used across all AzResourceMover modules.
# Pure functions: accept input, write to host, return nothing.
# ==============================================================================

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

function Write-Header {
<#
.SYNOPSIS
    Writes a full-width double-line banner to the console.
.PARAMETER Title
    The text to display in the banner.
#>
    param([string]$Title)
    $bar = "=" * 70
    Write-Host ""
    Write-Host $bar             -ForegroundColor DarkCyan
    Write-Host "  $Title"      -ForegroundColor Cyan
    Write-Host $bar             -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Section {
<#
.SYNOPSIS
    Writes a section divider with a label to the console.
.PARAMETER Title
    The section label to display.
#>
    param([string]$Title)
    Write-Host ""
    Write-Host "-- $Title $("-" * [Math]::Max(0, 65 - $Title.Length))" -ForegroundColor DarkGray
}

function Write-Log {
<#
.SYNOPSIS
    Writes a timestamped, colour-coded log line to the console.
.PARAMETER Message
    The message to display.
.PARAMETER Level
    Severity level: INFO (default), OK, WARN, ERROR, DETAIL.
#>
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","DETAIL")]
        [string]$Level = "INFO"
    )
    $colour = switch ($Level) {
        "INFO"   { "Cyan"     }
        "OK"     { "Green"    }
        "WARN"   { "Yellow"   }
        "ERROR"  { "Red"      }
        "DETAIL" { "DarkGray" }
        default  { "White"    }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $colour
}

Export-ModuleMember -Function Write-Header, Write-Section, Write-Log
