# Azure Non-Movable Resource Checker
# Reads move support data and checks against your resources CSV

param (
    [string]$InputCsv = "Azureresources.csv",
    [string]$OutputCsv = "NonMovable_Results.csv"
)

$MoveSupportUrl = "https://raw.githubusercontent.com/tfitzmac/resource-capabilities/master/move-support-resources.csv"
$MoveSupportCsv = "move-support-resources.csv"

Write-Host "Downloading latest Azure move support data..." -ForegroundColor Cyan

# Download the move support CSV
Invoke-WebRequest -Uri $MoveSupportUrl -OutFile $MoveSupportCsv

# Import both CSVs
$MoveSupport = Import-Csv -Path $MoveSupportCsv
$Resources = Import-Csv -Path $InputCsv

# Create output file with header
"Resource Name,Resource Type,Move Resource Group,Move Subscription,Non-Movable" | Out-File -FilePath $OutputCsv -Encoding utf8

$NonMovableList = @()

foreach ($res in $Resources) {
    $resName = $res."Name"  # or $res.name depending on your CSV
    $resType = $res."Resource Type"

    $found = $false

    foreach ($support in $MoveSupport) {
        if ($resType -like "*$($support.Resource)*") {
            $moveRG = $support."Move Resource Group"
            $moveSub = $support."Move Subscription"
            $nonMovable = if ($moveRG -eq '0' -or $moveSub -eq '0') { "YES" } else { "NO" }

            "$resName,$resType,$moveRG,$moveSub,$nonMovable" | Out-File -FilePath $OutputCsv -Append -Encoding utf8

            if ($nonMovable -eq "YES") {
                $NonMovableList += $resType
            }
            $found = $true
            break
        }
    }

    if (-not $found) {
        "$resName,$resType,Unknown,Unknown,Unknown" | Out-File -FilePath $OutputCsv -Append -Encoding utf8
    }
}

# Summary
Write-Host "`nAnalysis Complete!" -ForegroundColor Green
Write-Host "Total resources checked: $($Resources.Count)" -ForegroundColor White
Write-Host "Non-movable resource types found: $($NonMovableList.Count)" -ForegroundColor Red

$NonMovableList | Sort-Object -Unique | ForEach-Object {
    Write-Host " - $_" -ForegroundColor Yellow
}

Write-Host "`nFull results saved to: $OutputCsv" -ForegroundColor Cyan