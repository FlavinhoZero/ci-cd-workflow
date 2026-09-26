<#
.SYNOPSIS
    Validates that all consumer repositories reference the correct workflow version.

.DESCRIPTION
    Checks all consumer repos for their ci.yml workflow reference and reports
    which ones are on @main, @vX.Y.Z, or old SHA pins.

.NOTES
    Run from the root of the TradBin workspace.
    Requires: gh CLI authenticated.
#>

param(
    [string[]]$Repos = @(
        'lambdaPrice', 'lambdaUsrCalcula', 'lambdaSellOrderBinance', 'lambdaCrudUsr',
        'lambdaMarketFeatures', 'lambdaVolatility', 'lambdaNewsRSS', 'lambdaAppAuth',
        'lambdaAppPayments', 'lambdaAppCore', 'apigatewayApp', 'dynamoUsr',
        'dynamoUsrRange', 'dynamoPrice', 'dynamoPayments', 'dynamoVolatility',
        'dynamoMarketFeatures', 'dynamoOrderTrade', 'ec2Proxy', 'eventbridgeCron',
        'snsPriceCollected', 'snspricedropTrade', 'sqsPriceCollectedUsrCalcula',
        'sqsPriceCollectedMarketFeatures', 'sqsUsrDrop'
    ),
    [string]$WorkflowDir = '.github/workflows',
    [string]$CiFile = 'ci.yml'
)

$Owner = 'FlavinhoZero'
$CiCdWorkflow = 'ci-cd-workflow'

function Get-WorkflowType {
    param([string]$Repo)
    
    $lambdaRepos = @(
        'lambdaPrice', 'lambdaUsrCalcula', 'lambdaSellOrderBinance', 'lambdaCrudUsr',
        'lambdaMarketFeatures', 'lambdaVolatility', 'lambdaNewsRSS', 'lambdaAppAuth',
        'lambdaAppPayments', 'lambdaAppCore'
    )
    
    if ($lambdaRepos -contains $Repo) {
        return 'lambda-ci.yml'
    }
    return 'infra-ci.yml'
}

function Check-Repo {
    param([string]$Repo)
    
    $workflowType = Get-WorkflowType $Repo
    $CiPath = "$Repo\$WorkflowDir\$CiFile"
    
    if (-not (Test-Path $CiPath)) {
        return @{ Repo = $Repo; Status = 'MISSING'; Reference = 'N/A'; Workflow = $workflowType }
    }
    
    $content = Get-Content $CiPath -Raw
    
    # Extract the uses: line
    $pattern = "uses:\s+$Owner/$CiCdWorkflow/\.github/workflows/$workflowType@([a-zA-Z0-9._-]+)"
    if ($content -match $pattern) {
        $ref = $matches[1]
        if ($ref -eq 'main') {
            $status = 'CURRENT (@main)'
        } elseif ($ref -match '^v\d+\.\d+\.\d+$') {
            $status = "PINNED ($ref)"
        } else {
            $status = "OLD SHA ($ref)"
        }
        return @{ Repo = $Repo; Status = $status; Reference = $ref; Workflow = $workflowType }
    } else {
        return @{ Repo = $Repo; Status = 'NO MATCH'; Reference = 'N/A'; Workflow = $workflowType }
    }
}

# Main execution
Write-Host "=== Consumer CI Reference Validation ===" -ForegroundColor Cyan
Write-Host "Checking $($Repos.Count) repositories..." -ForegroundColor Cyan
Write-Host ""

$results = @()
$onMain = 0
$onTag = 0
$onSha = 0
$missing = 0

foreach ($Repo in $Repos) {
    $result = Check-Repo $Repo
    $results += $result
    
    switch ($result.Status) {
        'CURRENT (@main)' { $onMain++; $color = 'Green' }
        { $_ -like 'PINNED*' } { $onTag++; $color = 'Cyan' }
        { $_ -like 'OLD SHA*' } { $onSha++; $color = 'Red' }
        'MISSING' { $missing++; $color = 'Yellow' }
        default { $missing++; $color = 'Yellow' }
    }
    
    Write-Host "[$($result.Repo)] $($result.Status) - uses $($result.Workflow)@$($result.Reference)" -ForegroundColor $color
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "@main (latest):     $onMain" -ForegroundColor Green
Write-Host "@vX.Y.Z (pinned):   $onTag" -ForegroundColor Cyan
Write-Host "Old SHA (stale):    $onSha" -ForegroundColor Red
Write-Host "Missing/Error:      $missing" -ForegroundColor Yellow
Write-Host "Total:              $($Repos.Count)" -ForegroundColor Cyan

if ($onSha -gt 0) {
    Write-Host ""
    Write-Warning "$onSha repositories still on old SHA pins - need migration"
    exit 1
} elseif ($missing -gt 0) {
    Write-Warning "$missing repositories have missing or unparseable ci.yml"
    exit 1
} else {
    Write-Host ""
    Write-Host "All repositories validated successfully!" -ForegroundColor Green
}