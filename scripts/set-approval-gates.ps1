<#
.SYNOPSIS
    Configures required reviewers on the 'production' environment for all consumer repos.

.DESCRIPTION
    This script adds the required_reviewers protection rule to the 'production'
    environment in each consumer repository. This enables the manual approval
    gate for production deploys (Milestone 3 of Plan 020).

    The script reads the repo list from repos-config.local.json (same as
    sync-environments.ps1 and migrate-consumers.ps1).

.NOTES
    Run from the TradBin workspace root (e:\Code\TradBin).
    Requires: gh CLI authenticated with admin access to consumer repos.
    GitHub Free tier: Environments + required reviewers WORK on private repos.
#>

param(
    [string]$Reviewer = "",  # defaults to owner from config
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$script:LogPath = "set-approval-gates.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $script:LogPath -Value $logEntry
}

# Ler configuração local (owner + repos) — arquivo NÃO versionado
$configPath = Join-Path $PSScriptRoot "repos-config.local.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Arquivo de configuração não encontrado: $configPath. Copie repos-config.local.example.json para repos-config.local.json e preencha."
    exit 1
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$Owner = $config.owner
$Repos = @($config.repos)
if ($Reviewer -eq "") { $Reviewer = $Owner }

Write-Log "========================================="
Write-Log "Iniciando set-approval-gates.ps1"
Write-Log "Owner: $Owner"
Write-Log "Reviewer: $Reviewer"
Write-Log "DryRun: $DryRun"
Write-Log "VerifyOnly: $VerifyOnly"
Write-Log "========================================="

$updated = 0
$skipped = 0
$errors = 0

foreach ($repo in $Repos) {
    Write-Log "Configurando approval gate para $repo..."

    # Verificar se environment production existe
    $envCheck = gh api "repos/$Owner/$repo/environments/production" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  [$repo] ERRO - Environment 'production' não existe. Rode sync-environments.ps1 primeiro." -ForegroundColor Red
        $errors++
        continue
    }

    if ($VerifyOnly) {
        # Apenas verificar estado atual
        $envData = gh api "repos/$Owner/$repo/environments/production" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  [$repo] ERRO - Falha ao ler environment" -ForegroundColor Red
            continue
        }
        $hasReviewers = $envData | ConvertFrom-Json | ForEach-Object { $_.protection_rules | Where-Object { $_.type -eq 'required_reviewers' } }
        if ($hasReviewers) {
            $reviewers = $hasReviewers.reviewers.login -join ', '
            Write-Log "  [$repo] OK - Required reviewers: $reviewers" -ForegroundColor Green
        } else {
            Write-Log "  [$repo] FALTA - Sem required_reviewers configurado" -ForegroundColor Yellow
        }
        continue
    }

    # Configurar required_reviewers
    $body = @{
        reviewers = @(@{ type = "User"; login = $Reviewer })
    } | ConvertTo-Json -Depth 3

    if ($DryRun) {
        Write-Log "  [$repo] DRY-RUN - Would set required_reviewers to $Reviewer"
        $updated++
        continue
    }

    # Write JSON to temp file for gh api --input
    $tempBody = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempBody, $body, [System.Text.Encoding]::UTF8)
    try {
        $result = gh api --method PUT "repos/$Owner/$repo/environments/production" --input $tempBody 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  [$repo] OK - Required reviewer $Reviewer configurado" -ForegroundColor Green
            $updated++
        } else {
            Write-Log "  [$repo] ERRO - $result" -ForegroundColor Red
            $errors++
        }
    } finally {
        if (Test-Path $tempBody) { Remove-Item $tempBody -Force }
    }
}

Write-Log "========================================="
Write-Log "Resumo: $updated atualizados, $skipped pulados, $errors erros"
Write-Log "========================================="

if ($errors -gt 0) { exit 1 }