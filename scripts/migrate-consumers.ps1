<#
.SYNOPSIS
    Migrates consumer repositories from pinned SHA to @main (or @vX.Y.Z) reference.

.DESCRIPTION
    Updates the ci.yml in each consumer repo to reference the ci-cd-workflow via
    @main (or a specific version tag). Handles BOTH branches that matter:
      - main    -> used by workflow_dispatch (production deploy)
      - develop -> used by push events (test deploy)
    Repos without a develop branch are handled gracefully.

    Idempotent: repos already on the target reference are skipped.

.NOTES
    Run from the TradBin workspace root (e:\Code\TradBin).
    Requires: git, gh CLI authenticated with write access to consumer repos.
#>

param(
    [string]$Reference = '@main',  # @main or @v1.1.0
    [string[]]$Branches = @('main', 'develop'),
    [string[]]$Repos = @(
        'lambdaPrice', 'lambdaUsrCalcula', 'lambdaSellOrderBinance', 'lambdaCrudUsr',
        'lambdaMarketFeatures', 'lambdaVolatility', 'lambdaNewsRSS', 'lambdaAppAuth',
        'lambdaAppPayments', 'lambdaAppCore', 'lambdaCalculaDrop', 'apigatewayApp',
        'dynamoUsr', 'dynamoUsrRange', 'dynamoPrice', 'dynamoPayments',
        'dynamoVolatility', 'dynamoMarketFeatures', 'dynamoOrderTrade', 'ec2Proxy',
        'eventbridgeCron', 'snsPriceCollected', 'snspricedropTrade',
        'sqsPriceCollectedUsrCalcula', 'sqsPriceCollectedMarketFeatures', 'sqsUsrDrop'
    ),
    [string]$CiFile = '.github/workflows/ci.yml',
    [switch]$DryRun,
    [switch]$SkipDevelop
)

$ErrorActionPreference = 'Continue'
$Owner = 'FlavinhoZero'
$CiCdWorkflow = 'ci-cd-workflow'

# Git writes normal progress/warnings to stderr; PowerShell would treat those as
# errors under ErrorActionPreference='Stop'. We therefore check $LASTEXITCODE
# explicitly instead of relying on exceptions.
function Invoke-Git {
    param([string[]]$GitArgs)
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    return @{ Output = $out; Code = $code }
}

if ($SkipDevelop) { $Branches = @('main') }

# Regex: match the reusable-workflow reference regardless of which workflow file
# (lambda-ci.yml / infra-ci.yml) and regardless of the current ref (SHA or tag).
$Pattern = "uses:\s+$Owner/$CiCdWorkflow/\.github/workflows/([a-zA-Z0-9._-]+)@[a-zA-Z0-9._-]+(\s*#[^\r\n]*)?"

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    # Resolve to an absolute path: [System.IO.File] uses the .NET working
    # directory, which PowerShell's Push-Location does NOT change.
    $abs = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($abs, $Content, $enc)
}

function Test-RemoteBranch {
    param([string]$Branch)
    $r = Invoke-Git @('ls-remote', '--heads', 'origin', $Branch)
    return ($r.Code -eq 0 -and $r.Output)
}

function Update-RepoBranch {
    param([string]$Repo, [string]$Branch, [string]$Reference)

    if (-not (Test-Path $CiFile)) {
        Write-Host "  [$Repo/$Branch] SKIP - $CiFile not found" -ForegroundColor Yellow
        return 'missing'
    }

    $content = Get-Content $CiFile -Raw

    if ($content -notmatch $Pattern) {
        Write-Host "  [$Repo/$Branch] SKIP - no ci-cd-workflow reference found" -ForegroundColor Yellow
        return 'nomatch'
    }

    $currentRef = $matches[0] -replace '.*@', '' -replace '\s.*', ''
    if ($currentRef -eq $Reference.TrimStart('@')) {
        Write-Host "  [$Repo/$Branch] ALREADY on $Reference" -ForegroundColor DarkGray
        return 'already'
    }

    $replacement = 'uses: ' + $Owner + '/' + $CiCdWorkflow + '/.github/workflows/$1' + $Reference
    $newContent = $content -replace $Pattern, $replacement

    if ($newContent -eq $content) {
        Write-Host "  [$Repo/$Branch] SKIP - no change produced" -ForegroundColor Yellow
        return 'nomatch'
    }

    if ($DryRun) {
        Write-Host "  [$Repo/$Branch] DRY RUN - would set $currentRef -> $Reference" -ForegroundColor Yellow
        return 'updated'
    }

    Write-Utf8NoBom -Path $CiFile -Content $newContent
    $r1 = Invoke-Git @('add', $CiFile)
    if ($r1.Code -ne 0) { throw "git add failed: $($r1.Output -join ' ')" }
    $r2 = Invoke-Git @('commit', '-m', "chore(ci): reference reusable workflow via $Reference", '--quiet')
    if ($r2.Code -ne 0) { throw "git commit failed: $($r2.Output -join ' ')" }
    $r3 = Invoke-Git @('push', 'origin', $Branch, '--quiet')
    if ($r3.Code -ne 0) { throw "git push failed: $($r3.Output -join ' ')" }
    Write-Host "  [$Repo/$Branch] UPDATED $currentRef -> $Reference (pushed)" -ForegroundColor Green
    return 'updated'
}

# --- Main ---
Write-Host "=== Consumer Migration to $Reference ===" -ForegroundColor Cyan
Write-Host "Repos: $($Repos.Count) | Branches: $($Branches -join ', ') | DryRun: $DryRun" -ForegroundColor Cyan
Write-Host ""

$stats = @{ updated = 0; already = 0; missing = 0; nomatch = 0; error = 0 }

foreach ($Repo in $Repos) {
    if (-not (Test-Path $Repo)) {
        Write-Host "[$Repo] ERROR - folder not found" -ForegroundColor Red
        $stats.error++
        continue
    }

    Write-Host "[$Repo]" -ForegroundColor Cyan
    Push-Location $Repo
    try {
        $originalBranch = (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Output
        $dirty = (Invoke-Git @('status', '--porcelain')).Output

        Invoke-Git @('fetch', 'origin', '--prune', '--quiet') | Out-Null

        foreach ($Branch in $Branches) {
            if (-not (Test-RemoteBranch $Branch)) {
                Write-Host "  [$Repo/$Branch] SKIP - branch does not exist on remote" -ForegroundColor DarkGray
                continue
            }

            # Stash local changes so checkout is safe; restore afterwards.
            $stashed = $false
            if ($dirty) {
                $rs = Invoke-Git @('stash', 'push', '-u', '-m', "pre-migration-$Repo", '--quiet')
                $stashed = ($rs.Code -eq 0)
            }

            try {
                $rc = Invoke-Git @('checkout', '-B', $Branch, "origin/$Branch", '--quiet')
                if ($rc.Code -ne 0) { throw "checkout failed: $($rc.Output -join ' ')" }
                $result = Update-RepoBranch -Repo $Repo -Branch $Branch -Reference $Reference
                $stats[$result]++
            } catch {
                Write-Host "  [$Repo/$Branch] ERROR - $($_.Exception.Message)" -ForegroundColor Red
                $stats.error++
            } finally {
                if ($stashed) { Invoke-Git @('stash', 'pop', '--quiet') | Out-Null }
            }
        }

        # Restore original branch
        if ($originalBranch -and $originalBranch -ne 'HEAD') {
            Invoke-Git @('checkout', $originalBranch, '--quiet') | Out-Null
        }
    } catch {
        Write-Host "[$Repo] ERROR - $($_.Exception.Message)" -ForegroundColor Red
        $stats.error++
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Updated:  $($stats.updated)" -ForegroundColor Green
Write-Host "Already:  $($stats.already)" -ForegroundColor DarkGray
Write-Host "Missing:  $($stats.missing)" -ForegroundColor Yellow
Write-Host "NoMatch:  $($stats.nomatch)" -ForegroundColor Yellow
Write-Host "Errors:   $($stats.error)" -ForegroundColor Red

if ($stats.error -gt 0) { exit 1 }
