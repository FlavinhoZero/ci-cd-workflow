<#
.SYNOPSIS
    Executes chaos test scenarios automatically.
    Breaks main in various ways, verifies alerting + rollback + recovery.

.DESCRIPTION
    Automates the chaos test from docs/CHAOS_TEST.md.
    Requires: gh CLI, access to pilot repo.

.NOTES
    Run from ci-cd-workflow directory.
#>

param(
    [string]$Owner = 'FlavinhoZero',
    [string]$PilotRepo = 'lambdaPrice',
    [string]$CiCdWorkflow = 'ci-cd-workflow',
    [string]$Scenario = 'syntax',  # syntax, provider, secret
    [switch]$DryRun
)

function Get-CurrentSha {
    param([string]$Repo)
    $sha = gh api "repos/$Owner/$Repo/commits/main" --jq '.sha'
    return $sha.Substring(0, 7)
}

function Trigger-Deploy {
    param([string]$Repo, [string]$Ref = 'develop')
    $run = gh api --method POST "repos/$Owner/$Repo/actions/workflows/ci.yml/dispatches" -f ref="$Ref"
    return $run | ConvertFrom-Json | Select-Object -ExpandProperty id
}

function Wait-For-Run {
    param([string]$Repo, [int]$RunId, [int]$TimeoutMinutes = 10)
    $start = Get-Date
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    
    while ((Get-Date) -lt $timeout) {
        $run = gh api "repos/$Owner/$Repo/actions/runs/$RunId" --jq '{status: .status, conclusion: .conclusion}'
        $status = $run.status
        $conclusion = $run.conclusion
        
        if ($status -eq 'completed') {
            return $conclusion
        }
        Start-Sleep -Seconds 30
    }
    return 'timeout'
}

function Inject-Chaos {
    param([string]$Scenario)
    
    switch ($Scenario) {
        'syntax' {
            Write-Host "Injecting: Syntax error in lambda-ci.yml" -ForegroundColor Yellow
            if (-not $DryRun) {
                echo "invalid: yaml: [" >> ".github/workflows/lambda-ci.yml"
                git add ".github/workflows/lambda-ci.yml"
                git commit -m "CHAOS: syntax error in lambda-ci.yml"
                git push origin main
            }
        }
        'provider' {
            Write-Host "Injecting: Bad terraform provider version" -ForegroundColor Yellow
            if (-not $DryRun) {
                (Get-Content ".github/workflows/lambda-ci.yml") -replace 'terraform-provider-aws_5\.100\.0', 'terraform-provider-aws_999.0.0' | Set-Content ".github/workflows/lambda-ci.yml"
                git add ".github/workflows/lambda-ci.yml"
                git commit -m "CHAOS: bad terraform provider version"
                git push origin main
            }
        }
        'secret' {
            Write-Host "Injecting: Broken secret reference" -ForegroundColor Yellow
            if (-not $DryRun) {
                (Get-Content ".github/workflows/lambda-ci.yml") -replace 'AWS_DEPLOY_ROLE_NAME', 'AWS_DEPLOY_ROLE_NAME_MISSING' | Set-Content ".github/workflows/lambda-ci.yml"
                git add ".github/workflows/lambda-ci.yml"
                git commit -m "CHAOS: broken secret reference"
                git push origin main
            }
        }
        default {
            Write-Error "Unknown scenario: $Scenario"
            exit 1
        }
    }
}

function Execute-ChaosTest {
    Write-Host "=== CHAOS TEST: $Scenario ===" -ForegroundColor Cyan
    $testStart = Get-Date
    
    # 1. Baseline
    $baselineSha = Get-CurrentSha $CiCdWorkflow
    Write-Host "Baseline: $baselineSha" -ForegroundColor Green
    
    # 2. Inject chaos
    Inject-Chaos $Scenario
    $chaosTime = Get-Date
    $chaosSha = Get-CurrentSha $CiCdWorkflow
    Write-Host "Chaos pushed: $chaosSha" -ForegroundColor Red
    
    # 3. Trigger deploy
    Write-Host "Triggering deploy in $PilotRepo..." -ForegroundColor Cyan
    $runId = Trigger-Deploy $PilotRepo
    Write-Host "Run ID: $runId"
    
    # 4. Wait for failure
    Write-Host "Waiting for failure..." -ForegroundColor Yellow
    $conclusion = Wait-For-Run $PilotRepo $runId 10
    $failureTime = Get-Date
    
    if ($conclusion -ne 'failure') {
        Write-Warning "Deploy did not fail: $conclusion"
    } else {
        Write-Host "Deploy failed as expected" -ForegroundColor Green
    }
    
    # 5. Rollback
    Write-Host "Rolling back..." -ForegroundColor Cyan
    if (-not $DryRun) {
        git revert HEAD --no-edit
        git push origin main
    }
    $rollbackTime = Get-Date
    $rollbackSha = Get-CurrentSha $CiCdWorkflow
    Write-Host "Rollback: $rollbackSha" -ForegroundColor Green
    
    # 6. Recovery deploy
    Write-Host "Triggering recovery..." -ForegroundColor Cyan
    $runId2 = Trigger-Deploy $PilotRepo
    $conclusion2 = Wait-For-Run $PilotRepo $runId2 10
    $recoveryTime = Get-Date
    
    if ($conclusion2 -eq 'success') {
        Write-Host "Recovery SUCCEEDED" -ForegroundColor Green
    } else {
        Write-Error "Recovery FAILED: $conclusion2"
    }
    
    # 7. Metrics
    $totalMin = ($recoveryTime - $testStart).TotalMinutes
    $alertMin = ($failureTime - $chaosTime).TotalMinutes
    $rollbackMin = ($rollbackTime - $failureTime).TotalMinutes
    $recoveryMin = ($recoveryTime - $rollbackTime).TotalMinutes
    
    Write-Host ""
    Write-Host "=== CHAOS TEST METRICS ===" -ForegroundColor Cyan
    Write-Host "Total:        $([math]::Round($totalMin, 1)) min (target: < 10)"
    Write-Host "Alert:        $([math]::Round($alertMin, 1)) min (target: < 1)"
    Write-Host "Rollback:     $([math]::Round($rollbackMin, 1)) min (target: < 2)"
    Write-Host "Recovery:     $([math]::Round($recoveryMin, 1)) min (target: < 7)"
    
    $passed = ($totalMin -lt 10) -and ($conclusion2 -eq 'success')
    Write-Host (if ($passed) { "✅ PASSED" } else { "❌ FAILED" }) -ForegroundColor (if ($passed) { 'Green' } else { 'Red' })
    return $passed
}

# Main
Write-Host "=== Chaos Test Runner ===" -ForegroundColor Cyan
Write-Host "Scenario: $Scenario" -ForegroundColor Cyan
Write-Host "Pilot: $PilotRepo" -ForegroundColor Cyan
Write-Host "DryRun: $DryRun" -ForegroundColor Cyan
Write-Host ""

if (-not $DryRun) {
    $confirm = Read-Host "This will break main and trigger real deploys. Continue? (y/N)"
    if ($confirm -ne 'y') { exit 0 }
}

$passed = Execute-ChaosTest
exit (if ($passed) { 0 } else { 1 })