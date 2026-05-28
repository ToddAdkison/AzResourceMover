# Azure Resource Move Support Checker - Optimized with Hash Table
param (
    [string]$MoveSupportCsv = "move-support-resources.csv",
    [string]$AzResourcesCsv = "Azresources.csv",
    [string]$OutputCsv = "MoveCheck_Results.csv"
)

# Import CSVs
$moveSupport = Import-Csv -Path $MoveSupportCsv
$azResources = Import-Csv -Path $AzResourcesCsv

# === Build Hash Table for fast lookup ===
$supportHash = @{}
foreach ($item in $moveSupport) {
    $key = $item.Resource.Trim()
    if (-not $supportHash.ContainsKey($key)) {
        $supportHash[$key] = $item
    }
}

# Create output file
"Name,Type,ResourceGroup,MoveResourceGroup,MoveSubscription,NonMovable" | 
    Out-File -FilePath $OutputCsv -Encoding utf8

$nonMovableCount = 0

Write-Host "Processing $($azResources.Count) resources..." -ForegroundColor Cyan

foreach ($resource in $azResources) {
    $name = $resource.name
    $type = $resource.type
    $rg   = $resource.resourceGroup

    $matched = $false
    $typeLower = $type.ToLower()

    # Check against hash table
    foreach ($key in $supportHash.Keys) {
        if ($typeLower -like "*$($key.ToLower())*") {
            $support = $supportHash[$key]
            
            $moveRG = $support."Move Resource Group"
            $moveSub = $support."Move Subscription"
            $isNonMovable = if ($moveRG -eq '0' -or $moveSub -eq '0') { "YES" } else { "NO" }

            "$name,$type,$rg,$moveRG,$moveSub,$isNonMovable" | 
                Out-File -FilePath $OutputCsv -Append -Encoding utf8

            if ($isNonMovable -eq "YES") {
                $nonMovableCount++
                Write-Host "Non-movable → $name" -ForegroundColor Yellow
            }

            $matched = $true
            break
        }
    }

    if (-not $matched) {
        "$name,$type,$rg,Unknown,Unknown,Unknown" | 
            Out-File -FilePath $OutputCsv -Append -Encoding utf8
    }
}

# Summary
Write-Host "`nAnalysis Complete!" -ForegroundColor Green
Write-Host "Total resources checked : $($azResources.Count)" -ForegroundColor White
Write-Host "Non-movable resources   : $nonMovableCount" -ForegroundColor Red
Write-Host "Results saved to        : $OutputCsv" -ForegroundColor Cyan