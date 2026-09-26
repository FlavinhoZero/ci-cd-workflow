<#
.SYNOPSIS
    Migrates consumer repositories from pinned SHA to @main reference.
    Supports both @main and @vX.Y.Z tag pinning.

.DESCRIPTION
    This script updates the ci.yml files in consumer repositories to reference
    the ci-cd-workflow via @main (or a specific version tag). It handles both
    lambda-ci.yml and infra-ci.yml references.

.NOTES
    Run from the root of the TradBin workspace.
    Requires: gh CLI authenticated, write access to consumer repos.
#>

param(
    [string]$Reference = '@main',  # @main or @v1.1.0
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
    [string]$CiFile = 'ci.yml',
    [switch]$DryRun,
    [switch]$Force
)

$Owner = 'FlavinhoZero'
$CiCdWorkflow = 'ci-cd-workflow'

function Get-WorkflowType {
    param([string]$Repo)
    
    # Determine if repo uses lambda-ci.yml or infra-ci.yml
    # Lambda repos typically have 'lambda' in name or have src/ directory
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

function Update-CiYml {
    param(
        [string]$Repo,
        [string]$WorkflowFile,
        [string]$Reference
    )
    
    $CiPath = "$Repo\$WorkflowDir\$CiFile"
    
    if (-not (Test-Path $CiPath)) {
        Write-Warning "[$Repo] ci.yml not found at $CiPath"
        return $false
    }
    
    $content = Get-Content $CiPath -Raw
    
    # Pattern to match the uses: line for ci-cd-workflow
    $pattern = "uses:\s+$Owner/$CiCdWorkflow/\.github/workflows/$WorkflowFile@[a-zA-Z0-9._-]+"
    $replacement = "uses: $Owner/$CiCdWorkflow/.github/workflows/$WorkflowFile$Reference"
    
    if ($content -match $pattern) {
        $newContent = $content -replace $pattern, $replacement
        
        if ($DryRun) {
            Write-Host "[$Repo] DRY RUN: Would update $WorkflowFile reference to $Reference" -ForegroundColor Yellow
            return $true
        }
        
        Set-Content -Path $CiPath -Value $newContent -Encoding UTF8
        Write-Host "[$Repo] Updated $WorkflowFile reference to $Reference" -ForegroundColor Green
        return $true
    } else {
        Write-Warning "[$Repo] Pattern not found for $WorkflowFile in $CiPath"
        return $false
    }
}

function Commit-And-Push {
    param([string]$Repo, [string]$Message)
    
    if ($DryRun) {
        Write-Host "[$Repo] DRY RUN: Would commit and push" -ForegroundColor Yellow
        return
    }
    
    Push-Location $Repo
    try {
        git add "$WorkflowDir\$CiFile"
        git commit -m "$Message"
        git push origin HEAD:main
        Write-Host "[$Repo] Committed and pushed to main" -ForegroundColor Cyan
    } catch {
        Write-Error "[$Repo] Failed to commit/push: $_"
    } finally {
        Pop-Location
    }
}

# Main execution
Write-Host "=== Consumer Migration to $Reference ===" -ForegroundColor Cyan
Write-Host "Target repos: $($Repos.Count)" -ForegroundColor Cyan
Write-Host "Dry run: $DryRun" -ForegroundColor Cyan
Write-Host ""

$success = 0
$failed = 0

foreach ($Repo in $Repos) {
    $workflowType = Get-WorkflowType $Repo
    Write-Host "Processing $Repo (uses $workflowType)..." -ForegroundColor Cyan
    
    $updated = Update-CiYml -Repo $Repo -WorkflowFile $workflowType -Reference $Reference
    
    if ($updated) {
        $success++
        if (-not $DryRun) {
            Commit-AndPush -Repo $Repo -Message "chore: migrate CI reference to $Reference"
        }
    } else {
        $failed++
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Success: $success" -ForegroundColor Green
Write-Host "Failed:  $failed" -ForegroundColor Red

if ($failed -gt 0) {
    exit 1
}