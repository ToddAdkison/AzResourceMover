<#
.SYNOPSIS
    Checks dependencies and validates (or executes) Azure resource moves.

.PARAMETER SourceSubscriptionId
    The subscription ID containing the source resources.
.PARAMETER SourceResourceGroupName
    The name of the source resource group.
.PARAMETER TargetResourceGroupName
    The name of the target resource group.
.PARAMETER TargetSubscriptionId
    The target subscription ID. Defaults to SourceSubscriptionId if omitted.
.PARAMETER ResourceIds
    Optional specific resource IDs to evaluate. Defaults to all resources in source RG.
.PARAMETER SkipDependencyCheck
    Skips lock, dependency, and conflict checks. Runs Azure API validation only.
.PARAMETER Move
    After a successful validation, executes the resource move.
.PARAMETER DebugMode
    Activates debug logging. Writes a timestamped .log file to the script directory.

.EXAMPLE
    # Validate only
    .\AzResourceMover.ps1 `
        -SourceSubscriptionId    "aaaa-bbbb-cccc-dddd" `
        -SourceResourceGroupName "my-source-rg" `
        -TargetResourceGroupName "my-target-rg"

.EXAMPLE
    # Validate and move across subscriptions
    .\AzResourceMover.ps1 `
        -SourceSubscriptionId    "aaaa-bbbb-cccc-dddd" `
        -SourceResourceGroupName "my-source-rg" `
        -TargetSubscriptionId    "eeee-ffff-gggg-hhhh" `
        -TargetResourceGroupName "my-target-rg" `
        -Move

.EXAMPLE
    # Validate with full debug logging
    .\AzResourceMover.ps1 `
        -SourceSubscriptionId    "aaaa-bbbb-cccc-dddd" `
        -SourceResourceGroupName "my-source-rg" `
        -TargetResourceGroupName "my-target-rg" `
        -DebugMode
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$TargetResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TargetSubscriptionId = $SourceSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string[]]$ResourceIds = @(),

    [Parameter(Mandatory = $false)]
    [switch]$SkipDependencyCheck,

    [Parameter(Mandatory = $false)]
    [switch]$Move,

    [Parameter(Mandatory = $false)]
    [switch]$DebugMode
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# ==============================================================================
# IMPORT MODULES
# Loaded in dependency order: Output first, Debug second, then consumers.
# ==============================================================================

$modulesRoot = Join-Path $PSScriptRoot "Modules"

Import-Module (Join-Path $modulesRoot "AzRM.Output\AzRM.Output.psd1")         -Force
Import-Module (Join-Path $modulesRoot "AzRM.Debug\AzRM.Debug.psd1")           -Force
Import-Module (Join-Path $modulesRoot "AzRM.Preflight\AzRM.Preflight.psd1")   -Force
Import-Module (Join-Path $modulesRoot "AzRM.Analysis\AzRM.Analysis.psd1")     -Force
Import-Module (Join-Path $modulesRoot "AzRM.Operations\AzRM.Operations.psd1") -Force

# ==============================================================================
# ENTRY POINT
# ==============================================================================

Write-Header "AzResourceMover - Dependency Check and Move Validation"

if ($Move) {
    Write-Log "Mode: VALIDATE + MOVE  (-Move switch is ON  - resources WILL be moved if validation passes)" "WARN"
} else {
    Write-Log "Mode: VALIDATE ONLY    (-Move switch is OFF - no resources will be moved)" "INFO"
}

# Initialise debug log before anything else so all subsequent calls are captured
if ($DebugMode) {
    Initialize-DebugLog -OutputDirectory $PSScriptRoot | Out-Null
    Write-DebugSection -Title "Run Configuration"
    Write-DebugLog -Message "SourceSubscriptionId    : $SourceSubscriptionId"
    Write-DebugLog -Message "SourceResourceGroupName : $SourceResourceGroupName"
    Write-DebugLog -Message "TargetSubscriptionId    : $TargetSubscriptionId"
    Write-DebugLog -Message "TargetResourceGroupName : $TargetResourceGroupName"
    Write-DebugLog -Message "SkipDependencyCheck     : $($SkipDependencyCheck.IsPresent)"
    Write-DebugLog -Message "Move                    : $($Move.IsPresent)"
}

# -- Prerequisites --
if (-not (Test-ModuleAvailable "Az.Resources")) { exit 1 }
if (-not (Test-AzureSession))                   { exit 1 }

Write-Section "VALIDATING RESOURCE GROUPS"
if (-not (Test-ResourceGroupExists -SubscriptionId    $SourceSubscriptionId `
                                   -ResourceGroupName $SourceResourceGroupName)) { exit 1 }

if (-not (Test-ResourceGroupExists -SubscriptionId    $TargetSubscriptionId `
                                   -ResourceGroupName $TargetResourceGroupName)) { exit 1 }

Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

# -- Collect resources --
Write-Section "COLLECTING RESOURCES"
$resources = Resolve-ResourceIds -SubscriptionId    $SourceSubscriptionId `
                                 -ResourceGroupName $SourceResourceGroupName `
                                 -ExplicitIds       $ResourceIds

if ($resources.Count -eq 0) {
    Write-Log "No resources to evaluate. Exiting." "WARN"
    if ($DebugMode) { Close-DebugLog }
    exit 0
}

$resolvedIds = @($resources | Select-Object -ExpandProperty ResourceId)

# -- Dependency checks --
$lockResults = @()
$depResults  = @()
$conflicts   = @()

if (-not $SkipDependencyCheck) {
    Write-Section "RUNNING DEPENDENCY CHECKS"

    Write-Log "Checking resource locks..." "INFO"
    $lockResults = @(Get-ResourceLockStatus -Resources $resources)

    Write-Log "Checking cross-group dependencies..." "INFO"
    $depResults = @(Get-CrossGroupDependencies -ResourceGroupName  $SourceResourceGroupName `
                                               -SourceResourceIds $resolvedIds)

    Write-Log "Checking for naming conflicts in target..." "INFO"
    $conflicts = @(Get-NamingConflicts -SourceSubscriptionId    $SourceSubscriptionId `
                                       -TargetSubscriptionId    $TargetSubscriptionId `
                                       -TargetResourceGroupName $TargetResourceGroupName `
                                       -SourceResources         $resources)
} else {
    Write-Log "Dependency checks skipped (-SkipDependencyCheck was set)." "WARN"
}

# -- Azure API validation --
$validationResult = Invoke-MoveValidation `
    -SourceSubscriptionId    $SourceSubscriptionId `
    -SourceResourceGroupName $SourceResourceGroupName `
    -TargetSubscriptionId    $TargetSubscriptionId `
    -TargetResourceGroupName $TargetResourceGroupName `
    -ResourceIds             $resolvedIds

# -- Assemble and display report --
$report = New-Report `
    -Resources         $resources `
    -LockResults       $lockResults `
    -DependencyResults $depResults `
    -ConflictResults   $conflicts `
    -ValidationResult  $validationResult `
    -RunConfig         @{
        SourceSubscriptionId    = $SourceSubscriptionId
        SourceResourceGroupName = $SourceResourceGroupName
        TargetSubscriptionId    = $TargetSubscriptionId
        TargetResourceGroupName = $TargetResourceGroupName
        SkipDependencyCheck     = $SkipDependencyCheck.IsPresent
    }

Write-Header "VALIDATION REPORT"
Write-Report -Report $report

# -- Execute move if -Move supplied and all checks passed --
if ($Move) {
    if (-not $report.OverallPass) {
        Write-Log "Move SKIPPED - one or more validation checks failed. Resolve issues and retry." "ERROR"
        if ($DebugMode) { Close-DebugLog }
        exit 1
    }

    Write-Header "EXECUTING MOVE"
    $moveResult = Invoke-ResourceMove `
        -SourceSubscriptionId    $SourceSubscriptionId `
        -SourceResourceGroupName $SourceResourceGroupName `
        -TargetSubscriptionId    $TargetSubscriptionId `
        -TargetResourceGroupName $TargetResourceGroupName `
        -ResourceIds             $resolvedIds

    Write-MoveResult -MoveResult $moveResult

    if ($DebugMode) { Close-DebugLog }
    if (-not $moveResult.Succeeded) { exit 1 }
} else {
    if ($DebugMode) { Close-DebugLog }
}
