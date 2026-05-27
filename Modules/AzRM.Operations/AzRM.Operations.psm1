# ==============================================================================
# AzRM.Operations.psm1
# Azure API validation (Section 5), move execution (Section 6), and
# report assembly and display (Section 7).
# Pure functions: accept structured inputs, return structured result objects.
# Requires: AzRM.Output, AzRM.Debug
# ==============================================================================

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# SECTION 5 - AZURE API VALIDATION
# Calls validateMoveResources via Invoke-AzRestMethod.
# Body is serialized manually to guarantee 'resources' is a flat JSON array.
# (Invoke-AzResourceAction -Parameters wraps nested arrays in an extra object
# layer, causing: "Unexpected character encountered while parsing value: {")
# ------------------------------------------------------------------------------

function Invoke-MoveValidation {
<#
.SYNOPSIS
    Calls the Azure validateMoveResources REST API to check move eligibility.
.DESCRIPTION
    Uses Invoke-AzRestMethod with an explicitly serialized JSON body to avoid
    the array-wrapping bug in Invoke-AzResourceAction -Parameters.
    HTTP 202 (Accepted) and 204 (No Content) both indicate a passing result.
    Debug logging is automatic when AzRM.Debug has been initialised.
.PARAMETER SourceSubscriptionId
    Subscription containing the source resource group.
.PARAMETER SourceResourceGroupName
    Name of the source resource group.
.PARAMETER TargetSubscriptionId
    Subscription containing the target resource group.
.PARAMETER TargetResourceGroupName
    Name of the target resource group.
.PARAMETER ResourceIds
    Array of top-level resource IDs to validate.
.OUTPUTS
    PSCustomObject with Passed [bool], StatusCode [int], and Errors [array].
#>
    param(
        [string]   $SourceSubscriptionId,
        [string]   $SourceResourceGroupName,
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [string[]] $ResourceIds
    )

    Write-DebugContextSwitch -SubscriptionId $SourceSubscriptionId -CalledFrom "Invoke-MoveValidation"
    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

    $targetRgId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName"

    $body = [ordered]@{
        resources           = [array]$ResourceIds
        targetResourceGroup = $targetRgId
    } | ConvertTo-Json -Depth 5 -Compress

    $apiPath = "/subscriptions/$SourceSubscriptionId/resourceGroups/" +
               "$SourceResourceGroupName/validateMoveResources?api-version=2021-04-01"

    Write-Log "Calling validateMoveResources API (may take up to 15 minutes)..." "INFO"

    if (Test-DebugEnabled) {
        Write-DebugSection  -Title "Invoke-MoveValidation"
        Write-DebugRequest  -ApiPath $apiPath -Method "POST" -Body $body
    }

    try {
        $response = Invoke-AzRestMethod -Path $apiPath -Method POST -Payload $body

        if (Test-DebugEnabled) {
            Write-DebugResponse -StatusCode $response.StatusCode `
                                -Headers    $response.Headers `
                                -Content    $response.Content
        }

        # 202 Accepted   = async validation queued (pass)
        # 204 No Content = sync validation passed
        $passed = $response.StatusCode -in @(202, 204)

        $errors = if (-not $passed -and $response.Content) {
            $errBody = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errBody.error.details) {
                @($errBody.error.details | ForEach-Object {
                    [PSCustomObject]@{
                        Resource = $_.target
                        Code     = $_.code
                        Message  = $_.message
                    }
                })
            } elseif ($errBody.error) {
                @([PSCustomObject]@{
                    Resource = "N/A"
                    Code     = $errBody.error.code
                    Message  = $errBody.error.message
                })
            } else { @() }
        } else { @() }

        return [PSCustomObject]@{
            Passed     = $passed
            StatusCode = $response.StatusCode
            Errors     = $errors
        }
    }
    catch {
        if (Test-DebugEnabled) {
            Write-DebugLog -Message "Exception: $($_.Exception.Message)" -Section "VALIDATION"
        }
        return [PSCustomObject]@{
            Passed     = $false
            StatusCode = 0
            Errors     = @([PSCustomObject]@{
                Resource = "N/A"
                Code     = "RequestFailed"
                Message  = $_.Exception.Message
            })
        }
    }
}

# ------------------------------------------------------------------------------
# SECTION 6 - MOVE EXECUTION
# ------------------------------------------------------------------------------

function Invoke-ResourceMove {
<#
.SYNOPSIS
    Moves validated top-level resources to the target resource group.
.DESCRIPTION
    Calls Move-AzResource with Force. Automatically includes
    -DestinationSubscriptionId when moving across subscriptions.
    Returns a structured result - does not throw on failure.
    Debug logging is automatic when AzRM.Debug has been initialised.
.PARAMETER SourceSubscriptionId
    Subscription containing the source resources.
.PARAMETER SourceResourceGroupName
    Name of the source resource group.
.PARAMETER TargetSubscriptionId
    Subscription containing the target resource group.
.PARAMETER TargetResourceGroupName
    Name of the target resource group.
.PARAMETER ResourceIds
    Array of validated top-level resource IDs to move.
.OUTPUTS
    PSCustomObject with Succeeded [bool], MovedCount [int],
    FailedResources [array], DurationSeconds [decimal], and CompletedAt [string].
#>
    param(
        [string]   $SourceSubscriptionId,
        [string]   $SourceResourceGroupName,
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [string[]] $ResourceIds
    )

    Write-DebugContextSwitch -SubscriptionId $SourceSubscriptionId -CalledFrom "Invoke-ResourceMove"
    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

    if (Test-DebugEnabled) {
        Write-DebugSection -Title "Invoke-ResourceMove"
        Write-DebugLog -Message "Resource count       : $($ResourceIds.Count)"       -Section "MOVE"
        Write-DebugLog -Message "Source RG            : $SourceResourceGroupName"     -Section "MOVE"
        Write-DebugLog -Message "Target RG            : $TargetResourceGroupName"     -Section "MOVE"
        Write-DebugLog -Message "Cross-subscription   : $($TargetSubscriptionId -ne $SourceSubscriptionId)" -Section "MOVE"
        foreach ($id in $ResourceIds) {
            Write-DebugLog -Message "  Moving: $id" -Section "MOVE"
        }
    }

    $startTime = Get-Date
    Write-Log "Moving $($ResourceIds.Count) resource(s) to '$TargetResourceGroupName'..." "INFO"

    try {
        $moveParams = @{
            ResourceId                   = $ResourceIds
            DestinationResourceGroupName = $TargetResourceGroupName
            Force                        = $true
            ErrorAction                  = "Stop"
        }

        if ($TargetSubscriptionId -ne $SourceSubscriptionId) {
            $moveParams["DestinationSubscriptionId"] = $TargetSubscriptionId
            Write-Log "Cross-subscription move detected. Target subscription: $TargetSubscriptionId" "INFO"
        }

        Move-AzResource @moveParams | Out-Null

        $duration = (Get-Date) - $startTime

        Write-DebugLog -Message "Move SUCCEEDED. Duration: $([math]::Round($duration.TotalSeconds,1))s" -Section "MOVE"

        return [PSCustomObject]@{
            Succeeded       = $true
            MovedCount      = $ResourceIds.Count
            FailedResources = @()
            DurationSeconds = [math]::Round($duration.TotalSeconds, 1)
            CompletedAt     = (Get-Date -Format "o")
        }
    }
    catch {
        $duration = (Get-Date) - $startTime

        Write-DebugLog -Message "Move FAILED. Duration: $([math]::Round($duration.TotalSeconds,1))s" -Section "MOVE"
        Write-DebugLog -Message "Exception: $($_.Exception.Message)" -Section "MOVE"

        return [PSCustomObject]@{
            Succeeded       = $false
            MovedCount      = 0
            FailedResources = @([PSCustomObject]@{
                ResourceId = "See error message"
                Error      = $_.Exception.Message
            })
            DurationSeconds = [math]::Round($duration.TotalSeconds, 1)
            CompletedAt     = (Get-Date -Format "o")
        }
    }
}

function Write-MoveResult {
<#
.SYNOPSIS
    Displays the result of a move operation to the console.
.PARAMETER MoveResult
    The PSCustomObject returned by Invoke-ResourceMove.
#>
    param([object]$MoveResult)

    Write-Section "MOVE RESULT"

    if ($MoveResult.Succeeded) {
        Write-Log "Move SUCCEEDED." "OK"
        Write-Log "  Resources moved : $($MoveResult.MovedCount)" "OK"
        Write-Log "  Duration        : $($MoveResult.DurationSeconds)s" "OK"
        Write-Log "  Completed at    : $($MoveResult.CompletedAt)" "OK"
    } else {
        Write-Log "Move FAILED after $($MoveResult.DurationSeconds)s." "ERROR"
        foreach ($failure in $MoveResult.FailedResources) {
            Write-Log "  Resource : $($failure.ResourceId)" "ERROR"
            Write-Log "  Error    : $($failure.Error)"      "ERROR"
        }
    }
    Write-Host ""
}

# ------------------------------------------------------------------------------
# SECTION 7 - REPORT ASSEMBLY AND DISPLAY
# ------------------------------------------------------------------------------

function New-Report {
<#
.SYNOPSIS
    Assembles all check and validation results into a single report object.
.PARAMETER Resources
    Top-level resource objects collected from the source group.
.PARAMETER LockResults
    Output of Get-ResourceLockStatus.
.PARAMETER DependencyResults
    Output of Get-CrossGroupDependencies.
.PARAMETER ConflictResults
    Output of Get-NamingConflicts.
.PARAMETER ValidationResult
    Output of Invoke-MoveValidation.
.PARAMETER RunConfig
    Hashtable of the run parameters (subscriptions, resource groups, flags).
.OUTPUTS
    PSCustomObject representing the full report, including OverallPass [bool].
#>
    param(
        [object[]]  $Resources,
        [object[]]  $LockResults,
        [object[]]  $DependencyResults,
        [object[]]  $ConflictResults,
        [object]    $ValidationResult,
        [hashtable] $RunConfig
    )

    $lockedResources      = @($LockResults      | Where-Object { $_.HasLock })
    $externalDepResources = @($DependencyResults | Where-Object { $_.HasExternalDeps })

    [PSCustomObject]@{
        GeneratedAt     = (Get-Date -Format "o")
        Configuration   = $RunConfig
        ResourceCount   = $Resources.Count
        Resources       = @($Resources | Select-Object Name, ResourceType, ResourceId, Location)
        LockedResources = $lockedResources
        ExternalDeps    = $externalDepResources
        NamingConflicts = @($ConflictResults)
        Validation      = $ValidationResult
        OverallPass     = (
            $ValidationResult.Passed           -and
            $lockedResources.Count       -eq 0 -and
            $externalDepResources.Count  -eq 0 -and
            @($ConflictResults).Count    -eq 0
        )
    }
}

function Write-Report {
<#
.SYNOPSIS
    Displays the full validation report to the console.
.PARAMETER Report
    The PSCustomObject returned by New-Report.
#>
    param([object]$Report)

    Write-Section "RESOURCES COLLECTED ($($Report.ResourceCount))"
    $Report.Resources | ForEach-Object {
        Write-Log "$($_.ResourceType.PadRight(52)) $($_.Name)" "DETAIL"
    }

    Write-Section "LOCK CHECK"
    if ($Report.LockedResources.Count -eq 0) {
        Write-Log "No resource locks detected." "OK"
    } else {
        $Report.LockedResources | ForEach-Object {
            Write-Log "LOCKED: $($_.ResourceName)  [$($_.LockTypes -join ', ')]" "WARN"
            Write-Log "  Remove lock(s): $($_.LockNames -join ', ') before moving." "DETAIL"
        }
    }

    Write-Section "CROSS-GROUP DEPENDENCY CHECK"
    if ($Report.ExternalDeps.Count -eq 0) {
        Write-Log "No external dependencies detected." "OK"
    } else {
        $Report.ExternalDeps | ForEach-Object {
            Write-Log "EXTERNAL DEP: $($_.ResourceName) ($($_.ResourceType))" "WARN"
            $_.ExternalDependencies | ForEach-Object { Write-Log "  -> $_" "DETAIL" }
        }
    }

    Write-Section "NAMING CONFLICT CHECK"
    if ($Report.NamingConflicts.Count -eq 0) {
        Write-Log "No naming conflicts in the target resource group." "OK"
    } else {
        $Report.NamingConflicts | ForEach-Object {
            Write-Log "CONFLICT: '$($_.ResourceName)' ($($_.ResourceType)) already exists in target." "WARN"
        }
    }

    Write-Section "AZURE API VALIDATION"
    if ($Report.Validation.Passed) {
        Write-Log "Azure validation PASSED (HTTP $($Report.Validation.StatusCode))." "OK"
    } else {
        Write-Log "Azure validation FAILED (HTTP $($Report.Validation.StatusCode))." "ERROR"
        $Report.Validation.Errors | ForEach-Object {
            Write-Log "  Resource : $($_.Resource)" "ERROR"
            Write-Log "  Code     : $($_.Code)"     "ERROR"
            Write-Log "  Message  : $($_.Message)"  "ERROR"
        }
    }

    Write-Section "OVERALL RESULT"
    if ($Report.OverallPass) {
        Write-Log "ALL CHECKS PASSED - resources appear ready to move." "OK"
    } else {
        Write-Log "ONE OR MORE CHECKS FAILED - review warnings above before moving." "ERROR"
    }
    Write-Host ""
}

Export-ModuleMember -Function @(
    'Invoke-MoveValidation',
    'Invoke-ResourceMove',
    'Write-MoveResult',
    'New-Report',
    'Write-Report'
)
