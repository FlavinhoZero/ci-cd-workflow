<#
.SYNOPSIS
    Pins GitHub Actions to full commit SHAs for supply chain security.
    Fetches verified SHAs from GitHub releases and updates workflow files.

.DESCRIPTION
    This script addresses SonarCube security vulnerabilities:
    - "Use full commit SHA hash for this dependency" (High severity)
    - "Using dependencies without locking resolved versions" (Medium severity)
    
    It fetches the latest stable release SHA for each action and updates
    all workflow files in the ci-cd-workflow repository.

.NOTES
    Run from the ci-cd-workflow repository root.
    Requires: gh CLI authenticated, jq installed.
#>

param(
    [switch]$DryRun,
    [switch]$ForceUpdate,
    [string]$WorkflowDir = ".github\workflows"
)

# Action mappings: action_name -> { owner, repo, current_version_tag }
$ActionsToPin = @{
    "actions/checkout" = @{ Owner = "actions"; Repo = "checkout"; CurrentTag = "v4" }
    "actions/setup-python" = @{ Owner = "actions"; Repo = "setup-python"; CurrentTag = "v5" }
    "aws-actions/configure-aws-credentials" = @{ Owner = "aws-actions"; Repo = "configure-aws-credentials"; CurrentTag = "v4" }
    "hashicorp/setup-terraform" = @{ Owner = "hashicorp"; Repo = "setup-terraform"; CurrentTag = "v3" }
    "actions/upload-artifact" = @{ Owner = "actions"; Repo = "upload-artifact"; CurrentTag = "v4" }
    "actions/download-artifact" = @{ Owner = "actions"; Repo = "download-artifact"; CurrentTag = "v4" }
    "softprops/action-gh-release" = @{ Owner = "softprops"; Repo = "action-gh-release"; CurrentTag = "v1" }
    "actions/cache" = @{ Owner = "actions"; Repo = "cache"; CurrentTag = "v4" }
}

function Get-LatestReleaseSha {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$TagPrefix = "v"
    )
    
    try {
        # Get latest release (not pre-release)
        $release = gh api "repos/$Owner/$Repo/releases/latest" --jq '.tag_name, .target_commitish' 2>$null
        if (-not $release) {
            # Fallback: get latest tag matching pattern
            $tags = gh api "repos/$Owner/$Repo/tags" --jq '.[] | select(.name | startswith("'$TagPrefix'")) | .name' 2>$null
            if ($tags) {
                $latestTag = ($tags -split "`n") | Sort-Object { [version]$_.TrimStart($TagPrefix) } -Descending | Select-Object -First 1
                $commit = gh api "repos/$Owner/$Repo/git/ref/tags/$latestTag" --jq '.object.sha' 2>$null
                return $commit
            }
            return $null
        }
        
        $tagName = ($release -split "`n")[0]
        $commitSha = ($release -split "`n")[1]
        
        # If target_commitish is a branch, get the actual commit SHA for the tag
        if ($commitSha -match '^[a-f0-9]{40}$') {
            return $commitSha
        }
        
        # Get commit SHA for the tag
        $commit = gh api "repos/$Owner/$Repo/git/ref/tags/$tagName" --jq '.object.sha' 2>$null
        return $commit
    }
    catch {
        $errMsg = $PSItem.Exception.Message
        Write-Warning ("Failed to get SHA for {0}/{1}: {2}" -f $Owner, $Repo, $errMsg)
        return $null
    }
}

function Update-WorkflowFile {
    param(
        [string]$FilePath,
        [hashtable]$ShaMap
    )
    
    $content = Get-Content $FilePath -Raw
    $originalContent = $content
    $changes = 0
    
    foreach ($actionKey in $ShaMap.Keys) {
        $sha = $ShaMap[$actionKey]
        if (-not $sha) { continue }
        
        # Pattern: uses: owner/repo@vX or uses: owner/repo@vX.Y.Z
        $pattern = "uses:\s+$([regex]::Escape($actionKey))@[a-zA-Z0-9._-]+"
        $replacement = "uses: $actionKey@$sha  # $($ShaMap["${actionKey}_version"])"
        
        if ($content -match $pattern) {
            $content = $content -replace $pattern, $replacement
            $changes++
            Write-Host "  Updated: $actionKey -> $sha" -ForegroundColor Green
        }
        else {
            Write-Warning "  Pattern not found for $actionKey in $FilePath"
        }
    }
    
    if ($changes -gt 0) {
        if ($DryRun) {
            Write-Host "[DRY RUN] Would update $FilePath with $changes changes" -ForegroundColor Yellow
        }
        else {
            Set-Content -Path $FilePath -Value $content -Encoding UTF8
            Write-Host "Updated $FilePath with $changes changes" -ForegroundColor Cyan
        }
        return $true
    }
    return $false
}

# Main execution
Write-Host "=== GitHub Actions SHA Pinning Script ===" -ForegroundColor Cyan
Write-Host "Repository: ci-cd-workflow"
Write-Host "Workflow directory: $WorkflowDir"
Write-Host ""

# Fetch SHAs for all actions
$ShaMap = @{}
$VersionMap = @{}

Write-Host "Fetching latest release SHAs..." -ForegroundColor Yellow
foreach ($actionKey in $ActionsToPin.Keys) {
    $info = $ActionsToPin[$actionKey]
    Write-Host "  Querying $($info.Owner)/$($info.Repo) ($($info.CurrentTag))..." -NoNewline
    $sha = Get-LatestReleaseSha -Owner $info.Owner -Repo $info.Repo -TagPrefix $info.CurrentTag
    if ($sha) {
        $ShaMap[$actionKey] = $sha
        $VersionMap[$actionKey] = $info.CurrentTag
        Write-Host " OK ($sha)" -ForegroundColor Green
    }
    else {
        Write-Host " FAILED" -ForegroundColor Red
    }
}

# Add version info to ShaMap for comments
$keysToAdd = $ShaMap.Keys | Where-Object { $_ -notmatch '_version$' }
foreach ($key in $keysToAdd) {
    $ShaMap["${key}_version"] = $VersionMap[$key]
}

Write-Host ""
Write-Host "Found SHAs for $($ShaMap.Count / 2) actions:" -ForegroundColor Cyan
$ShaMap.Keys | Where-Object { $_ -notmatch '_version$' } | ForEach-Object {
    Write-Host "  $_@$($ShaMap[$_])  # $($ShaMap["${_}_version"])"
}

# Process workflow files
Write-Host ""
Write-Host "Processing workflow files..." -ForegroundColor Yellow
$workflowFiles = Get-ChildItem -Path $WorkflowDir -Filter "*.yml" -File
$totalChanges = 0

foreach ($file in $workflowFiles) {
    Write-Host "Processing $($file.Name)..." -ForegroundColor Cyan
    if (Update-WorkflowFile -FilePath $file.FullName -ShaMap $ShaMap) {
        $totalChanges++
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Files processed: $($workflowFiles.Count)"
Write-Host "Files updated: $totalChanges"
Write-Host "Actions pinned: $($ShaMap.Count / 2)"

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN COMPLETE - No files were modified." -ForegroundColor Yellow
    Write-Host "Run without -DryRun to apply changes." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "CHANGES APPLIED. Review with 'git diff' before committing." -ForegroundColor Green
}

# Show git diff if not dry run
if (-not $DryRun -and $totalChanges -gt 0) {
    Write-Host ""
    Write-Host "Git diff:" -ForegroundColor Cyan
    git diff $WorkflowDir
}