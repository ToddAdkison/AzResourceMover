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
#
# Flow:
#   POST validateMoveResources
#     204 No Content  -> validation complete, passed  (return immediately)
#     202 Accepted    -> async operation started      (poll until Succeeded/Failed)
#     other           -> validation failed            (return errors)
# ------------------------------------------------------------------------------

function Wait-AsyncOperation {
<#
.SYNOPSIS
    Private helper. Polls an Azure async operation URL until it reaches a
    terminal state (Succeeded, Failed, Canceled) or the timeout is reached.
.DESCRIPTION
    Azure returns an Azure-AsyncOperation or Location header on a 202 response.
    This function polls that URL on a configurable interval, logging progress,
    and returns once a definitive outcome is known.
.PARAMETER PollingUrl
    Full URL returned in the Azure-AsyncOperation or Location response header.
.PARAMETER TimeoutMinutes
    Maximum time to wait before returning a TimedOut failure.
.PARAMETER PollIntervalSeconds
    Seconds to wait between each poll request.
.PARAMETER StartTime
    The DateTime the original POST was made, used for elapsed time display.
.OUTPUTS
    PSCustomObject with Passed [bool], FinalStatus [string], and Errors [array].
#>
    param(
        [string]   $PollingUrl,
        [int]      $TimeoutMinutes,
        [int]      $PollIntervalSeconds,
        [datetime] $StartTime
    )

    $deadline  = $StartTime.AddMinutes($TimeoutMinutes)
    $pollCount = 0

    Write-Log "  Async operation started. Polling every ${PollIntervalSeconds}s (timeout: ${TimeoutMinutes}min)..." "INFO"
    Write-DebugLog -Message "Polling URL: $PollingUrl" -Section "POLL"

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds

        $pollCount++
        $elapsed = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)
        $remaining = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 1)
        Write-Log "  Poll #$pollCount — ${elapsed}s elapsed, ${remaining}min remaining..." "INFO"

        try {
            $pollResponse = Invoke-AzRestMethod -Uri $PollingUrl -Method GET -ErrorAction Stop

            Write-DebugLog -Message "Poll #$pollCount status code: $($pollResponse.StatusCode)" -Section "POLL"

            if (Test-DebugEnabled) {
                Write-DebugResponse -StatusCode $pollResponse.StatusCode `
                                    -Headers    $pollResponse.Headers `
                                    -Content    $pollResponse.Content
            }

            if (-not $pollResponse.Content) { continue }

            $pollBody = $pollResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $pollBody -or -not $pollBody.PSObject.Properties.Name -contains 'status') { continue }

            $status = $pollBody.status
            Write-Log "  Azure status: $status" "INFO"
            Write-DebugLog -Message "Azure async status: $status" -Section "POLL"

            switch ($status) {
                "Succeeded" {
                    Write-Log "Validation SUCCEEDED after ${elapsed}s." "OK"
                    return [PSCustomObject]@{
                        Passed      = $true
                        FinalStatus = $status
                        Errors      = @()
                    }
                }
                "Failed" {
                    $errors = @()
                    if ($pollBody.PSObject.Properties.Name -contains 'error') {
                        $err = $pollBody.error
                        if ($err.PSObject.Properties.Name -contains 'details' -and $err.details) {
                            $errors = @($err.details | ForEach-Object {
                                [PSCustomObject]@{
                                    Resource = if ($_.PSObject.Properties.Name -contains 'target')  { $_.target  } else { "N/A" }
                                    Code     = if ($_.PSObject.Properties.Name -contains 'code')    { $_.code    } else { "Unknown" }
                                    Message  = if ($_.PSObject.Properties.Name -contains 'message') { $_.message } else { "No message" }
                                }
                            })
                        } else {
                            $errors = @([PSCustomObject]@{
                                Resource = "N/A"
                                Code     = if ($err.PSObject.Properties.Name -contains 'code')    { $err.code    } else { "Unknown" }
                                Message  = if ($err.PSObject.Properties.Name -contains 'message') { $err.message } else { "No message" }
                            })
                        }
                    }
                    Write-Log "Validation FAILED after ${elapsed}s." "ERROR"
                    return [PSCustomObject]@{
                        Passed      = $false
                        FinalStatus = $status
                        Errors      = $errors
                    }
                }
                "Canceled" {
                    Write-Log "Validation was CANCELED after ${elapsed}s." "WARN"
                    return [PSCustomObject]@{
                        Passed      = $false
                        FinalStatus = $status
                        Errors      = @([PSCustomObject]@{
                            Resource = "N/A"
                            Code     = "Canceled"
                            Message  = "The async validation operation was canceled by Azure."
                        })
                    }
                }
                default {
                    # InProgress or unknown - keep polling
                    continue
                }
            }
        }
        catch {
            Write-Log "  Poll #$pollCount failed: $($_.Exception.Message)" "WARN"
            Write-DebugLog -Message "Poll #$pollCount exception: $($_.Exception.Message)" -Section "POLL"
        }
    }

    # Timeout reached
    $elapsed = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)
    Write-Log "Validation timed out after ${elapsed}s (limit: ${TimeoutMinutes}min)." "ERROR"
    Write-DebugLog -Message "Polling timed out after ${elapsed}s." -Section "POLL"

    return [PSCustomObject]@{
        Passed      = $false
        FinalStatus = "TimedOut"
        Errors      = @([PSCustomObject]@{
            Resource = "N/A"
            Code     = "ValidationTimedOut"
            Message  = "Validation did not complete within $TimeoutMinutes minutes. Increase -ValidationTimeoutMinutes or retry."
        })
    }
}

function Invoke-MoveValidation {
<#
.SYNOPSIS
    Calls the Azure validateMoveResources REST API and waits for a definitive result.
.DESCRIPTION
    Uses Invoke-AzRestMethod with an explicitly serialized JSON body to avoid
    the array-wrapping bug in Invoke-AzResourceAction -Parameters.

    204 No Content  -> validation complete, returns Passed = $true immediately.
    202 Accepted    -> async operation started. Polls the Azure-AsyncOperation URL
                       every -ValidationPollIntervalSeconds until Azure returns
                       Succeeded or Failed (or the timeout is reached).

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
.PARAMETER ValidationTimeoutMinutes
    Maximum minutes to wait for a Succeeded/Failed response. Default: 15.
.PARAMETER ValidationPollIntervalSeconds
    Seconds between each poll request when waiting on a 202. Default: 30.
.OUTPUTS
    PSCustomObject with Passed [bool], StatusCode [int], FinalStatus [string],
    and Errors [array].
#>
    param(
        [string]   $SourceSubscriptionId,
        [string]   $SourceResourceGroupName,
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [string[]] $ResourceIds,
        [int]      $ValidationTimeoutMinutes      = 15,
        [int]      $ValidationPollIntervalSeconds = 30
    )

    Write-DebugContextSwitch -SubscriptionId $SourceSubscriptionId -CalledFrom "Invoke-MoveValidation"
    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

    $targetRgId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName"

    $body = [ordered]@{
        resources           = [array]$ResourceIds
        targetResourceGroup = $targetRgId
    } | ConvertTo-Json -Depth 5 -Compress

    $apiPath  = "/subscriptions/$SourceSubscriptionId/resourceGroups/" +
                "$SourceResourceGroupName/validateMoveResources?api-version=2021-04-01"
    $startTime = Get-Date

    Write-Log "Calling validateMoveResources API..." "INFO"

    if (Test-DebugEnabled) {
        Write-DebugSection -Title "Invoke-MoveValidation"
        Write-DebugRequest -ApiPath $apiPath -Method "POST" -Body $body
    }

    try {
        $response = Invoke-AzRestMethod -Path $apiPath -Method POST -Payload $body

        if (Test-DebugEnabled) {
            Write-DebugResponse -StatusCode $response.StatusCode `
                                -Headers    $response.Headers `
                                -Content    $response.Content
        }

        # ── 204: synchronous pass - return immediately ─────────────────────────
        if ($response.StatusCode -eq 204) {
            Write-Log "Validation PASSED (HTTP 204 - synchronous)." "OK"
            return [PSCustomObject]@{
                Passed      = $true
                StatusCode  = 204
                FinalStatus = "Succeeded"
                Errors      = @()
            }
        }

        # ── 202: async operation queued - poll until terminal state ─────────────
        if ($response.StatusCode -eq 202) {
            Write-Log "HTTP 202 received - validation running asynchronously." "INFO"

            # Azure returns the polling URL in Azure-AsyncOperation or Location header
            $pollingUrl = $null
            if ($response.Headers -and $response.Headers['Azure-AsyncOperation']) {
                $pollingUrl = $response.Headers['Azure-AsyncOperation']
            } elseif ($response.Headers -and $response.Headers['Location']) {
                $pollingUrl = $response.Headers['Location']
            }

            if (-not $pollingUrl) {
                Write-Log "202 received but no polling URL found in response headers." "ERROR"
                Write-DebugLog -Message "Headers: $($response.Headers | ConvertTo-Json)" -Section "POLL"
                return [PSCustomObject]@{
                    Passed      = $false
                    StatusCode  = 202
                    FinalStatus = "NoPollingUrl"
                    Errors      = @([PSCustomObject]@{
                        Resource = "N/A"
                        Code     = "NoPollingUrl"
                        Message  = "Azure returned 202 but did not include an Azure-AsyncOperation or Location header."
                    })
                }
            }

            $asyncResult = Wait-AsyncOperation `
                -PollingUrl            $pollingUrl `
                -TimeoutMinutes        $ValidationTimeoutMinutes `
                -PollIntervalSeconds   $ValidationPollIntervalSeconds `
                -StartTime             $startTime

            return [PSCustomObject]@{
                Passed      = $asyncResult.Passed
                StatusCode  = 202
                FinalStatus = $asyncResult.FinalStatus
                Errors      = $asyncResult.Errors
            }
        }

        # ── Any other status code: failure ─────────────────────────────────────
        $errors = @()
        if ($response.Content) {
            $errBody = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errBody -and $errBody.error) {
                if ($errBody.error.PSObject.Properties.Name -contains 'details' -and $errBody.error.details) {
                    $errors = @($errBody.error.details | ForEach-Object {
                        [PSCustomObject]@{
                            Resource = $_.target
                            Code     = $_.code
                            Message  = $_.message
                        }
                    })
                } else {
                    $errors = @([PSCustomObject]@{
                        Resource = "N/A"
                        Code     = $errBody.error.code
                        Message  = $errBody.error.message
                    })
                }
            }
        }

        Write-Log "Validation FAILED (HTTP $($response.StatusCode))." "ERROR"
        return [PSCustomObject]@{
            Passed      = $false
            StatusCode  = $response.StatusCode
            FinalStatus = "Failed"
            Errors      = $errors
        }
    }
    catch {
        Write-DebugLog -Message "Exception: $($_.Exception.Message)" -Section "VALIDATION"
        return [PSCustomObject]@{
            Passed      = $false
            StatusCode  = 0
            FinalStatus = "RequestFailed"
            Errors      = @([PSCustomObject]@{
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
