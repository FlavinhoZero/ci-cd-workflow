<#
.SYNOPSIS
    Automates GitHub-side configuration for Milestone 1.
    Uses gh CLI to configure branch protection, environments, repo subscription.

.DESCRIPTION
    This script automates all GitHub-configurable items from the Milestone 1 checklist.
    Requires: gh CLI authenticated with admin:repo_hook, repo, admin:org scopes.

.NOTES
    Run from ci-cd-workflow directory.
    Some items (2FA, PAT, SSH) MUST be done manually in GitHub UI.
#>

param(
    [string]$Owner = "FlavinhoZero",
    [string]$Repo = "ci-cd-workflow",
    [string]$WebhookUrl = "",  # Set this to your Slack/Discord/Teams webhook URL
    [string[]]$ConsumerRepos = @(
        "lambdaPrice", "lambdaUsrCalcula", "lambdaSellOrderBinance", "lambdaCrudUsr",
        "lambdaMarketFeatures", "lambdaVolatility", "lambdaNewsRSS", "lambdaAppAuth",
        "lambdaAppPayments", "lambdaAppCore", "apigatewayApp", "dynamoUsr",
        "dynamoUsrRange", "dynamoPrice", "dynamoPayments", "dynamoVolatility",
        "dynamoMarketFeatures", "dynamoOrderTrade", "ec2Proxy", "eventbridgeCron",
        "snsPriceCollected", "snspricedropTrade", "sqsPriceCollectedUsrCalcula",
        "sqsPriceCollectedMarketFeatures", "sqsUsrDrop"
    ),
    [switch]$DryRun,
    [switch]$SkipBranchProtection,
    [switch]$SkipEnvironments,
    [switch]$SkipWebhook,
    [switch]$SkipConsumerEnvs
)

function Test-GhAuth {
    try {
        $user = gh api user --jq ".login"
        Write-Host "Authenticated as: $user" -ForegroundColor Green
        return $true
    } catch {
        Write-Error "gh CLI not authenticated. Run: gh auth login --scopes 'admin:repo_hook,repo,admin:org'"
        return $false
    }
}

function Set-BranchProtection {
    param([string]$Owner, [string]$Repo)
    
    Write-Host "Configuring branch protection for $Owner/$Repo..." -ForegroundColor Cyan
    
    # Personal accounts require restrictions with explicit empty arrays
    $protection = @{
        required_pull_request_reviews = @{
            required_approving_review_count = 1
            dismiss_stale_reviews = $true
            require_code_owner_reviews = $true
        }
        enforce_admins = $true
        required_status_checks = @{
            strict = $true
            contexts = @()  # Will be populated after workflows run
        }
        restrictions = @{
            users = @()
            teams = @()
        }
        required_linear_history = $true
        allow_force_pushes = $false
        allow_deletions = $false
        required_signatures = $true
    }
    
    $json = $protection | ConvertTo-Json -Depth 5
    
    if ($DryRun) {
        Write-Host "[DRY RUN] Would set branch protection:" -ForegroundColor Yellow
        Write-Host $json
        return
    }
    
    try {
        echo $json | gh api --method PUT "repos/$Owner/$Repo/branches/main/protection" --input -
        Write-Host "Branch protection configured successfully" -ForegroundColor Green
    } catch {
        Write-Error "Failed to set branch protection: $($_.Exception.Message)"
    }
}

function Create-Environment {
    param([string]$Owner, [string]$Repo, [string]$EnvName, [string[]]$Reviewers)
    
    Write-Host "Creating/updating environment '$EnvName' in $Owner/$Repo..." -ForegroundColor Cyan
    
    $envConfig = @{
        wait_timer = 0
        deployment_branch_policy = @{
            protected_branches = $true
            custom_branch_policies = $false
        }
    }
    
    # Only add reviewers if they exist (for personal accounts, owner is auto-collaborator)
    if ($Reviewers.Count -gt 0) {
        $envConfig.reviewers = @()
        foreach ($reviewer in $Reviewers) {
            $envConfig.reviewers += @{ type = "User"; login = $reviewer }
        }
    }
    
    $json = $envConfig | ConvertTo-Json -Depth 5
    
    if ($DryRun) {
        Write-Host "[DRY RUN] Would create environment ${EnvName}:" -ForegroundColor Yellow
        Write-Host $json
        return
    }
    
    try {
        echo $json | gh api --method PUT "repos/$Owner/$Repo/environments/$EnvName" --input -
        Write-Host "Environment '${EnvName}' configured" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create environment ${EnvName}: $($_.Exception.Message)"
    }
}

function Set-RepoSubscription {
    param([string]$Owner, [string]$Repo)
    
    Write-Host "Setting repo subscription to 'subscribed' (Watch -> All Activity)..." -ForegroundColor Cyan
    
    if ($DryRun) {
        Write-Host "[DRY RUN] Would set repo subscription to 'subscribed'" -ForegroundColor Yellow
        return
    }
    
    try {
        # PUT /repos/{owner}/{repo}/subscription
        $body = @{ subscribed = $true; ignored = $false } | ConvertTo-Json
        echo $body | gh api --method PUT "repos/$Owner/$Repo/subscription" --input -
        Write-Host "Repo subscription set to 'subscribed' (All Activity)" -ForegroundColor Green
    } catch {
        Write-Error "Failed to set repo subscription: $($_.Exception.Message)"
    }
}

function Create-Webhook {
    param([string]$Owner, [string]$Repo, [string]$Url)
    
    if (-not $Url) {
        Write-Warning "No webhook URL provided, skipping webhook creation"
        return
    }
    
    Write-Host "Creating webhook for $Owner/$Repo..." -ForegroundColor Cyan
    
    $webhook = @{
        name = "web"
        active = $true
        events = @("push", "branch_protection_rule")
        config = @{
            url = $Url
            content_type = "json"
            insecure_ssl = "0"
        }
    }
    
    $json = $webhook | ConvertTo-Json -Depth 5
    
    if ($DryRun) {
        Write-Host "[DRY RUN] Would create webhook:" -ForegroundColor Yellow
        Write-Host $json
        return
    }
    
    try {
        echo $json | gh api --method POST "repos/$Owner/$Repo/hooks" --input -
        Write-Host "Webhook created successfully" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create webhook: $($_.Exception.Message)"
    }
}

function Validate-ConsumerEnvs {
    param([string]$Owner, [string[]]$Repos)
    
    Write-Host "Validating production environments in consumer repos..." -ForegroundColor Cyan
    
    foreach ($Repo in $Repos) {
        try {
            $env = gh api "repos/$Owner/$Repo/environments/production" --jq ".reviewers | length"
            if ($env -gt 0) {
                Write-Host "[$Repo] production environment has $env reviewer(s)" -ForegroundColor Green
            } else {
                Write-Warning "[$Repo] production environment exists but has NO reviewers"
            }
        } catch {
            Write-Warning "[$Repo] production environment NOT found or not accessible"
        }
    }
}

# Main execution
Write-Host "=== Milestone 1 GitHub Automation ===" -ForegroundColor Cyan
Write-Host "Owner: $Owner" -ForegroundColor Cyan
Write-Host "Repo: $Repo" -ForegroundColor Cyan
Write-Host "DryRun: $DryRun" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-GhAuth)) { exit 1 }

# 1. Branch Protection (ci-cd-workflow)
if (-not $SkipBranchProtection) {
    Set-BranchProtection -Owner $Owner -Repo $Repo
    Write-Host ""
}

# 2. Environments in ci-cd-workflow (test, production)
if (-not $SkipEnvironments) {
    Create-Environment -Owner $Owner -Repo $Repo -EnvName "test" -Reviewers @()
    Create-Environment -Owner $Owner -Repo $Repo -EnvName "production" -Reviewers @()
    Write-Host ""
}

# 3. Repo subscription (Watch -> All Activity) for notifications
Set-RepoSubscription -Owner $Owner -Repo $Repo
Write-Host ""

# 4. Validate consumer production environments
if (-not $SkipConsumerEnvs) {
    Validate-ConsumerEnvs -Owner $Owner -Repos $ConsumerRepos
    Write-Host ""
}

Write-Host "=== GitHub Automation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "MANUAL STEPS STILL REQUIRED:" -ForegroundColor Yellow
Write-Host "1. Enable 2FA (TOTP/passkey) in GitHub Settings" -ForegroundColor Yellow
Write-Host "2. Create fine-grained PAT with minimal scopes" -ForegroundColor Yellow
Write-Host "3. Add SSH key with passphrase" -ForegroundColor Yellow
Write-Host "4. Enable secret scanning + push protection in repo settings" -ForegroundColor Yellow
Write-Host "5. Run rollback drill (docs/ROLLBACK_DRILL.md)" -ForegroundColor Yellow
Write-Host "6. Run chaos test (docs/CHAOS_TEST.md)" -ForegroundColor Yellow
Write-Host "7. Configure OIDC IAM role least privilege in AWS Console" -ForegroundColor Yellow
