# ==============================================================================
# AzRM.Analysis.psm1
# Dependency checks: resource locks, cross-group dependencies, naming conflicts.
# Pure functions: accept resource data, return structured result objects.
# Requires: AzRM.Output, AzRM.Debug
# ==============================================================================

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

function Get-ResourceLockStatus {
<#
.SYNOPSIS
    Checks each resource for ReadOnly or CanNotDelete management locks.
.DESCRIPTION
    A locked resource cannot be moved until the lock is removed. Returns one
    result object per resource regardless of whether a lock exists.
.PARAMETER Resources
    Array of Az resource objects to inspect.
.OUTPUTS
    Array of PSCustomObjects with ResourceId, ResourceName, ResourceType,
    HasLock, LockNames, and LockTypes.
#>
    param([object[]]$Resources)

    if (Test-DebugEnabled) {
        Write-DebugSection -Title "Get-ResourceLockStatus"
    }

    $Resources | ForEach-Object {
        $res   = $_
        $locks = Get-AzResourceLock `
                    -ResourceGroupName $res.ResourceGroupName `
                    -ResourceName      $res.Name `
                    -ResourceType      $res.ResourceType `
                    -ErrorAction       SilentlyContinue

        $hasLock   = ($null -ne $locks -and @($locks).Count -gt 0)
        $lockNames = if ($locks) { @($locks) | Select-Object -ExpandProperty Name }      else { @() }
        $lockTypes = if ($locks) { @($locks) | ForEach-Object { $_.Properties.level } } else { @() }

        if (Test-DebugEnabled) {
            $lockSummary = if ($hasLock) { "LOCKED [$($lockTypes -join ', ')]" } else { "no locks" }
            Write-DebugLog -Message "$($res.Name): $lockSummary" -Section "LOCKS"
        }

        [PSCustomObject]@{
            ResourceId   = $res.ResourceId
            ResourceName = $res.Name
            ResourceType = $res.ResourceType
            HasLock      = $hasLock
            LockNames    = $lockNames
            LockTypes    = $lockTypes
        }
    }
}

function Get-CrossGroupDependencies {
<#
.SYNOPSIS
    Inspects the ARM template dependsOn arrays for cross-group references.
.DESCRIPTION
    Exports the source resource group as an ARM template, then checks each
    resource's dependsOn list for IDs that fall outside the source group.
    Resources with external dependencies may fail or behave unexpectedly
    after a move.
.PARAMETER ResourceGroupName
    The source resource group to export and inspect.
.PARAMETER SourceResourceIds
    The resolved top-level resource IDs in the source group.
.OUTPUTS
    Array of PSCustomObjects with ResourceName, ResourceType,
    TotalDependencies, ExternalDependencies, and HasExternalDeps.
#>
    param(
        [string]   $ResourceGroupName,
        [string[]] $SourceResourceIds
    )

    Write-Log "Exporting ARM template to map dependencies..." "INFO"
    $tempFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.json')

    try {
        Export-AzResourceGroup `
            -ResourceGroupName $ResourceGroupName `
            -Path              $tempFile `
            -Force `
            -ErrorAction Stop | Out-Null

        # Log the raw ARM export before parsing
        Write-DebugArmExport -TemplatePath $tempFile

        $template      = Get-Content $tempFile -Raw | ConvertFrom-Json
        $sourceIdLower = $SourceResourceIds | ForEach-Object { $_.ToLower() }

        if (Test-DebugEnabled) {
            Write-DebugSection -Title "Get-CrossGroupDependencies - Parsing"
        }

        # Cast to [array] before iterating - Set-StrictMode -Version 2 throws
        # PropertyNotFoundException if ForEach-Object receives a single
        # PSCustomObject (no .Count) rather than a collection.
        [array]$templateResources = if ($template.PSObject.Properties.Name -contains 'resources' -and
                                        $null -ne $template.resources) {
            @($template.resources)
        } else { @() }

        if ($templateResources.Count -eq 0) {
            Write-Log "ARM template contained no resources to inspect." "WARN"
            return @()
        }

        foreach ($resource in $templateResources) {
            [array]$deps = if ($resource.PSObject.Properties.Name -contains 'dependsOn' -and
                               $null -ne $resource.dependsOn) {
                               @($resource.dependsOn)
                           } else { @() }

            [array]$externalDeps = @($deps | Where-Object {
                $_ -match '/subscriptions/' -and $_.ToLower() -notin $sourceIdLower
            })

            if (Test-DebugEnabled) {
                Write-DebugLog -Message "$($resource.name): $(@($deps).Count) dep(s), $($externalDeps.Count) external" -Section "DEPS"
                foreach ($ext in $externalDeps) {
                    Write-DebugLog -Message "  External: $ext" -Section "DEPS"
                }
            }

            [PSCustomObject]@{
                ResourceName         = $resource.name
                ResourceType         = $resource.type
                TotalDependencies    = @($deps).Count
                ExternalDependencies = $externalDeps
                HasExternalDeps      = ($externalDeps.Count -gt 0)
            }
        }
    }
    finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

function Get-NamingConflicts {
<#
.SYNOPSIS
    Checks the target resource group for resources with the same name and type
    as the source resources.
.DESCRIPTION
    A naming conflict means a resource with the same name and type already exists
    in the target group, which will cause the move to fail.
.PARAMETER SourceSubscriptionId
    Subscription ID of the source resource group.
.PARAMETER TargetSubscriptionId
    Subscription ID of the target resource group.
.PARAMETER TargetResourceGroupName
    Name of the target resource group.
.PARAMETER SourceResources
    Array of top-level Az resource objects from the source group.
.OUTPUTS
    Array of PSCustomObjects with ResourceName, ResourceType, and ResourceId.
    Empty array if no conflicts found.
#>
    param(
        [string]   $SourceSubscriptionId,
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [object[]] $SourceResources
    )

    Write-DebugContextSwitch -SubscriptionId $TargetSubscriptionId -CalledFrom "Get-NamingConflicts"
    Set-AzContext -SubscriptionId $TargetSubscriptionId | Out-Null

    $targetResources = @(Get-AzResource -ResourceGroupName $TargetResourceGroupName `
                                        -ErrorAction SilentlyContinue)

    if (Test-DebugEnabled) {
        Write-DebugSection -Title "Get-NamingConflicts"
        Write-DebugLog -Message "Target RG resource count: $($targetResources.Count)" -Section "CONFLICTS"
    }

    $conflicts = $SourceResources | Where-Object {
        $src = $_
        $targetResources | Where-Object {
            $_.Name -eq $src.Name -and $_.ResourceType -eq $src.ResourceType
        }
    } | ForEach-Object {
        Write-DebugLog -Message "CONFLICT: $($_.Name) ($($_.ResourceType))" -Section "CONFLICTS"
        [PSCustomObject]@{
            ResourceName = $_.Name
            ResourceType = $_.ResourceType
            ResourceId   = $_.ResourceId
        }
    }

    # Restore source subscription context before returning
    Write-DebugContextSwitch -SubscriptionId $SourceSubscriptionId -CalledFrom "Get-NamingConflicts (restore)"
    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
    return @($conflicts)
}

Export-ModuleMember -Function @(
    'Get-ResourceLockStatus',
    'Get-CrossGroupDependencies',
    'Get-NamingConflicts'
)
