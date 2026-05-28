# Azure Resource Move Support Checker - Optimized + Interactive HTML Report
param (
    [string]$MoveSupportCsv = "move-support-resources.csv",
    [string]$AzResourcesCsv = "Azresources.csv",
    [string]$OutputHtml = "Azure_Move_Report.html"
)

# Import CSVs
$moveSupport = Import-Csv -Path $MoveSupportCsv
$azResources = Import-Csv -Path $AzResourcesCsv

# Build Hash Table for fast lookup
$supportHash = @{}
foreach ($item in $moveSupport) {
    $key = $item.Resource.Trim()
    if (-not $supportHash.ContainsKey($key)) {
        $supportHash[$key] = $item
    }
}

$results = @()
$nonMovableCount = 0

Write-Host "Processing $($azResources.Count) resources..." -ForegroundColor Cyan

foreach ($resource in $azResources) {
    $name = $resource.name
    $type = $resource.type
    $rg   = $resource.resourceGroup
    $subId = if ($resource.subscriptionId) { $resource.subscriptionId } else { "N/A" }

    $matched = $false
    $typeLower = $type.ToLower()

    foreach ($key in $supportHash.Keys) {
        if ($typeLower -like "*$($key.ToLower())*") {
            $support = $supportHash[$key]
            
            $moveRG = $support."Move Resource Group"
            $moveSub = $support."Move Subscription"
            
            $nonMovableRG = if ($moveRG -eq '0') { "YES" } else { "NO" }
            $nonMovableSub = if ($moveSub -eq '0') { "YES" } else { "NO" }
            $overallNonMovable = if ($nonMovableRG -eq "YES" -or $nonMovableSub -eq "YES") { "YES" } else { "NO" }

            $results += [PSCustomObject]@{
                Name                = $name
                Type                = $type
                ResourceGroup       = $rg
                SubscriptionId      = $subId
                MoveResourceGroup   = $moveRG
                MoveSubscription    = $moveSub
                NonMovableRG        = $nonMovableRG
                NonMovableSub       = $nonMovableSub
                NonMovable          = $overallNonMovable
            }

            if ($overallNonMovable -eq "YES") { $nonMovableCount++ }
            $matched = $true
            break
        }
    }

    if (-not $matched) {
        $results += [PSCustomObject]@{
            Name                = $name
            Type                = $type
            ResourceGroup       = $rg
            SubscriptionId      = $subId
            MoveResourceGroup   = "Unknown"
            MoveSubscription    = "Unknown"
            NonMovableRG        = "Unknown"
            NonMovableSub       = "Unknown"
            NonMovable          = "Unknown"
        }
    }
}

# Generate Interactive HTML Report
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Azure Resource Move Analysis Report</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css">
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    <style>
        body { padding: 20px; }
        .non-movable { background-color: #f8d7da !important; color: #842029; }
        table th { cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <h1 class="mb-4">Azure Resource Move Support Report</h1>
        <div class="alert alert-info">
            Total Resources: <strong>$($results.Count)</strong> | 
            Non-Movable Resources: <strong class="text-danger">$nonMovableCount</strong>
        </div>
        <input type="text" id="searchInput" class="form-control mb-3" placeholder="Search by name, type, or resource group...">
"@

$htmlFooter = @"
    </div>
    <script>
        // Search functionality
        document.getElementById("searchInput").addEventListener("keyup", function() {
            let filter = this.value.toUpperCase();
            let rows = document.querySelectorAll("tbody tr");
            rows.forEach(row => {
                let text = row.textContent.toUpperCase();
                row.style.display = text.includes(filter) ? "" : "none";
            });
        });
    </script>
</body>
</html>
"@

# Convert results to HTML table
$htmlBody = $results | Select-Object Name, Type, ResourceGroup, SubscriptionId, 
                                NonMovableRG, NonMovableSub, NonMovable |
            ConvertTo-Html -Fragment -Property Name, Type, ResourceGroup, SubscriptionId, 
                           NonMovableRG, NonMovableSub, NonMovable

# Add Bootstrap table classes and styling
$htmlBody = $htmlBody -replace '<table>', '<table class="table table-striped table-hover">'
$htmlBody = $htmlBody -replace '<thead>', '<thead class="table-dark">'

# Highlight non-movable rows
$htmlBody = $htmlBody -replace '<tr><td>', '<tr class="non-movable"><td>' -replace '<tr><td>(?!Unknown)', '<tr class="non-movable"><td>'

# Combine and save
$htmlContent = $htmlHeader + $htmlBody + $htmlFooter
$htmlContent | Out-File -FilePath $OutputHtml -Encoding utf8

Write-Host "`nAnalysis Complete!" -ForegroundColor Green
Write-Host "Non-movable resources : $nonMovableCount" -ForegroundColor Red
Write-Host "Interactive report saved to: $OutputHtml" -ForegroundColor Cyan