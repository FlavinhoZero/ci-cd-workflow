<#
.SYNOPSIS
    Executes the rollback drill automatically.
    Breaks main, triggers deploy, rolls back, verifies recovery.

.DESCRIPTION
    Automates the rollback drill from docs/ROLLBACK_DRILL.md.
    Requires: gh CLI, access to pilot repo.

.NOTES
    Run from ci-cd-workflow directory.
#>

param(
    [string]$Owner = 'FlavinhoZero',
    [string]$PilotRepo = 'lambdaPrice',
    [string]$CiCdWorkflow = 'ci-cd-workflow',
    [int]$MaxTotalMinutes = 10,
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
    $runId = $run | ConvertFrom-Json | Select-Object -ExpandProperty id
    return $runId
}

function Wait-For-Run {
    param([string]$Repo, [int]$RunId, [int]$TimeoutMinutes = 10)
    
    $start = Get-Date
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    
    while ((Get-Date) -lt $timeout) {
        $run = gh api "repos/$Owner/$Repo/actions/runs/$RunId" --jq '{status: .status, conclusion: .conclusion}'
        $status = $run.status
        $conclusion = $run.conclusion
        
        Write-Host "  Run $RunId: $status / $conclusion"
        
        if ($status -eq 'completed') {
            return $conclusion
        }
        
        Start-Sleep -Seconds 30
    }
    
    return 'timeout'
}

function Execute-RollbackDrill {
    Write-Host "=== ROLLBACK DRILL STARTED ===" -ForegroundColor Cyan
    $drillStart = Get-Date
    
    # 1. Baseline
    $baselineSha = Get-CurrentSha $CiCdWorkflow
    Write-Host "Baseline SHA: $baselineSha" -ForegroundColor Green
    
    # 2. Inject failure
    Write-Host "Injecting failure..." -ForegroundColor Yellow
    if (-not $DryRun) {
        echo "# DRILL: intentional break for rollback test" >> ".github/workflows/lambda-ci.yml"
        git add ".github/workflows/lambda-ci.yml"
        git commit -m "DRILL: intentional break for rollback test"
        git push origin main
    }
    $breakTime = Get-Date
    $breakSha = Get-CurrentSha $CiCdWorkflow
    Write-Host "Break pushed: $breakSha" -ForegroundColor Red
    
    # 3. Trigger deploy in pilot repo
    Write-Host "Triggering deploy in $PilotRepo..." -ForegroundColor Cyan
    $runId = Trigger-Deploy $PilotRepo
    Write-Host "Deploy run ID: $runId"
    
    # 4. Wait for failure
    Write-Host "Waiting for failure..." -ForegroundColor Yellow
    $conclusion = Wait-For-Run $PilotRepo $runId 10
    $failureTime = Get-Date
    
    if ($conclusion -ne 'failure') {
        Write-Warning "Deploy did not fail as expected: $conclusion"
    } else {
        Write-Host "Deploy failed as expected" -ForegroundColor Green
    }
    
    # 5. Execute rollback
    Write-Host "Executing rollback..." -ForegroundColor Cyan
    if (-not $DryRun) {
        git revert HEAD --no-edit
        git push origin main
    }
    $rollbackTime = Get-Date
    $rollbackSha = Get-CurrentSha $CiCdWorkflow
    Write-Host "Rollback pushed: $rollbackSha" -ForegroundColor Green
    
    # 6. Trigger recovery deploy
    Write-Host "Triggering recovery deploy..." -ForegroundColor Cyan
    $runId2 = Trigger-Deploy $PilotRepo
    Write-Host "Recovery run ID: $runId2"
    
    # 7. Wait for success
    Write-Host "Waiting for recovery..." -ForegroundColor Yellow
    $conclusion2 = Wait-For-Run $PilotRepo $runId2 10
    $recoveryTime = Get-Date
    
    if ($conclusion2 -eq 'success') {
        Write-Host "Recovery deploy SUCCEEDED" -ForegroundColor Green
    } else {
        Write-Error "Recovery deploy FAILED: $conclusion2"
    }
    
    # 8. Metrics
    $totalMinutes = ($recoveryTime - $drillStart).TotalMinutes
    $detectionMinutes = ($failureTime - $breakTime).TotalMinutes
    $rollbackMinutes = ($rollbackTime - $failureTime).TotalMinutes
    $recoveryMinutes = ($recoveryTime - $rollbackTime).TotalMinutes
    
    Write-Host ""
    Write-Host "=== ROLLBACK DRILL METRICS ===" -ForegroundColor Cyan
    Write-Host "Total time:        $([math]::Round($totalMinutes, 1)) min (target: < $MaxTotalMinutes)"
    Write-Host "Detection time:    $([math]::Round($detectionMinutes, 1)) min"
    Write-Host "Rollback time:     $([math]::Round($rollbackMinutes, 1)) min"
    Write-Host "Recovery time:     $([math]::Round($recoveryMinutes, 1)) min"
    
    if ($totalMinutes -lt $MaxTotalMinutes -and $conclusion2 -eq 'success') {
        Write-Host ""
        Write-Host "✅ DRILL PASSED" -ForegroundColor Green
        return $true
    } else {
        Write-Host ""
        Write-Host "❌ DRILL FAILED" -ForegroundColor Red
        return $false
    }
}

# Main
Write-Host "=== Rollback Drill ===" -ForegroundColor Cyan
Write-Host "Pilot repo: $PilotRepo" -ForegroundColor Cyan
Write-Host "DryRun: $DryRun" -ForegroundColor Cyan
Write-Host ""

if (-not $DryRun) {
    $confirm = Read-Host "This will push to main and trigger real deploys. Continue? (y/N)"
    if ($confirm -ne 'y') {
        Write-Host "Aborted."
        exit 0
    }
}

$passed = Execute-RollbackDrill
exit (if ($passed) { 0 } else { 1 })