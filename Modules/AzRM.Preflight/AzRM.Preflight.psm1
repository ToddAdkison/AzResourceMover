# ==============================================================================
# AzRM.Preflight.psm1
# Prerequisite checks (Section 2) and resource collection (Section 3).
# Pure functions: validate environment and return resource objects.
# Requires: AzRM.Output, AzRM.Debug
# ==============================================================================

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# SECTION 2 - PREREQUISITE CHECKS
# ------------------------------------------------------------------------------

function Test-ModuleAvailable {
<#
.SYNOPSIS
    Checks whether a PowerShell module is installed and imports it if found.
.PARAMETER ModuleName
    The name of the module to check.
.OUTPUTS
    [bool] $true if available and imported, $false otherwise.
#>
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Log "$ModuleName is not installed. Run: Install-Module -Name Az -Scope CurrentUser" "ERROR"
        return $false
    }
    Import-Module $ModuleName -ErrorAction Stop
    return $true
}

function Test-AzureSession {
<#
.SYNOPSIS
    Verifies an active Azure session exists, prompting login if needed.
.OUTPUTS
    [bool] Always $true after a successful login or existing session.
#>
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-Log "No active Azure session. Launching login..." "WARN"
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
    }
    Write-Log "Authenticated as: $($ctx.Account.Id)" "OK"
    Write-DebugLog -Message "Session account : $($ctx.Account.Id)" -Section "PREFLIGHT"
    Write-DebugLog -Message "Tenant ID       : $($ctx.Tenant.Id)"  -Section "PREFLIGHT"
    return $true
}

function Test-ResourceGroupExists {
<#
.SYNOPSIS
    Confirms a resource group exists in the given subscription.
.PARAMETER SubscriptionId
    The subscription to check.
.PARAMETER ResourceGroupName
    The resource group name to look up.
.OUTPUTS
    [bool] $true if found, $false if not.
#>
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName
    )
    Write-DebugContextSwitch -SubscriptionId $SubscriptionId -CalledFrom "Test-ResourceGroupExists"
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Log "Resource group '$ResourceGroupName' not found in subscription '$SubscriptionId'." "ERROR"
        Write-DebugLog -Message "RG NOT FOUND: $ResourceGroupName in $SubscriptionId" -Section "PREFLIGHT"
        return $false
    }
    Write-Log "Resource group '$ResourceGroupName' confirmed." "OK"
    Write-DebugLog -Message "RG confirmed: $ResourceGroupName (Location: $($rg.Location))" -Section "PREFLIGHT"
    return $true
}

# ------------------------------------------------------------------------------
# SECTION 3 - RESOURCE COLLECTION
# ------------------------------------------------------------------------------

function Get-SourceResources {
<#
.SYNOPSIS
    Returns all Az resource objects from the specified resource group.
.PARAMETER SubscriptionId
    The subscription containing the resource group.
.PARAMETER ResourceGroupName
    The resource group to enumerate.
.OUTPUTS
    Array of Az resource objects.
#>
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName
    )
    Write-DebugContextSwitch -SubscriptionId $SubscriptionId -CalledFrom "Get-SourceResources"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $resources = Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    Write-Log "Found $($resources.Count) total resource(s) in '$ResourceGroupName'." "OK"

    if (Test-DebugEnabled) {
        Write-DebugSection -Title "Raw Resource List from Get-AzResource"
        foreach ($r in $resources) {
            Write-DebugLog -Message "$($r.ResourceType.PadRight(55)) $($r.Name)" -Section "RESOURCES"
        }
    }

    return $resources
}

function Test-IsTopLevel {
<#
.SYNOPSIS
    Returns $true if a resource ID belongs to a top-level (non-child) resource.
.DESCRIPTION
    Top-level IDs have exactly 3 segments after /providers/ (namespace/type/name).
    Child resources have 5 or more segments and move automatically with their parent.
.PARAMETER ResourceId
    The full Azure resource ID to evaluate.
.OUTPUTS
    [bool]
#>
    param([string]$ResourceId)
    $parts       = $ResourceId.ToLower() -split '/'
    $providerIdx = [Array]::IndexOf($parts, 'providers')
    return ($providerIdx -ge 0 -and ($parts.Count - $providerIdx - 1) -le 3)
}

function Select-TopLevelResources {
<#
.SYNOPSIS
    Filters a resource array to top-level resources only.
.PARAMETER Resources
    Array of Az resource objects to filter.
.OUTPUTS
    Filtered array of top-level Az resource objects.
#>
    param([object[]]$Resources)

    $top     = @($Resources | Where-Object { Test-IsTopLevel $_.ResourceId })
    $skipped = $Resources.Count - $top.Count

    if ($skipped -gt 0) {
        Write-Log "$skipped child resource(s) excluded (auto-moved with their parent)." "WARN"
        $Resources |
            Where-Object { -not (Test-IsTopLevel $_.ResourceId) } |
            ForEach-Object {
                Write-Log "  Child excluded: $($_.ResourceId)" "DETAIL"
                Write-DebugLog -Message "Child excluded: $($_.ResourceId)" -Section "FILTER"
            }
    }

    Write-Log "$($top.Count) top-level resource(s) will be evaluated." "OK"
    return $top
}

function Resolve-ResourceIds {
<#
.SYNOPSIS
    Resolves the final list of top-level resource objects to evaluate.
.DESCRIPTION
    If ExplicitIds are provided, scopes the result to those resources only.
    In both cases, child resources are filtered out via Select-TopLevelResources.
.PARAMETER SubscriptionId
    Source subscription ID.
.PARAMETER ResourceGroupName
    Source resource group name.
.PARAMETER ExplicitIds
    Optional array of specific resource IDs to scope the evaluation to.
.OUTPUTS
    Array of top-level Az resource objects.
#>
    param(
        [string]   $SubscriptionId,
        [string]   $ResourceGroupName,
        [string[]] $ExplicitIds
    )

    $all = Get-SourceResources -SubscriptionId    $SubscriptionId `
                               -ResourceGroupName $ResourceGroupName

    $scoped = if ($ExplicitIds -and $ExplicitIds.Count -gt 0) {
        Write-DebugLog -Message "Scoping to $($ExplicitIds.Count) explicit resource ID(s)." -Section "FILTER"
        $all | Where-Object { $_.ResourceId -in $ExplicitIds }
    } else {
        $all
    }

    $result = Select-TopLevelResources -Resources @($scoped)

    Write-DebugResourceList -ResourceIds @($result | Select-Object -ExpandProperty ResourceId) `
                            -Stage "After top-level filter"
    return $result
}

Export-ModuleMember -Function @(
    'Test-ModuleAvailable',
    'Test-AzureSession',
    'Test-ResourceGroupExists',
    'Get-SourceResources',
    'Test-IsTopLevel',
    'Select-TopLevelResources',
    'Resolve-ResourceIds'
)
