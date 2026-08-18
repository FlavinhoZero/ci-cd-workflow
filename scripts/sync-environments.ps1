# sync-environments.ps1 - Script para criar Environments em todos os repositórios TradBin

<#
.SYNOPSIS
    Script para criar Environments test/production em múltiplos repositórios TradBin.

.DESCRIPTION
    Este script cria os Environments test e production em todos os repositórios Lambda/DynamoDB
    do TradBin, configurando as variáveis necessárias.

.PARAMETER AWSAccountId
    ID da conta AWS a ser configurada nas variáveis de ambiente.

.PARAMETER Region
    Região AWS padrão (padrão: sa-east-1).

.PARAMETER Reviewer
    Login do reviewer obrigatório para o ambiente production.

.EXAMPLE
    .\sync-environments.ps1 -AWSAccountId "AWS_ACCOUNT_ID_PLACEHOLDER" -Reviewer "FlavinhoZero"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AWSAccountId,
    [string]$Region = "sa-east-1",
    [string]$Reviewer = "FlavinhoZero"
)

$ErrorActionPreference = "Stop"
$script:LogPath = "sync-environments.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $script:LogPath -Value $logEntry
}

# Lista de repositórios TradBin
$Repos = @(
    "repo01", "repo02", "repo03", "repo04",
    "repo05", "repo06", "repo07", "repo08",
    "repo09", "repo10", "repo11", "repo12", "repo13"
)

Write-Log "========================================="
Write-Log "Iniciando sync-environments.ps1"
Write-Log "AWS Account ID: $AWSAccountId"
Write-Log "Região: $Region"
Write-Log "Reviewer: $Reviewer"
Write-Log "========================================="

foreach ($repo in $Repos) {
    Write-Log "Configurando Environments para $repo..."
    
    # Criar Environment test
    Write-Log "Criando Environment test..."
    gh api --method PUT "repos/FlavinhoZero/$repo/environments/test" 2>&1 | Out-Null
    gh variable set AWS_ACCOUNT_ID --env test --repo "FlavinhoZero/$repo" --body "$AWSAccountId" 2>&1 | Out-Null
    gh variable set TF_VAR_region --env test --repo "FlavinhoZero/$repo" --body $Region 2>&1 | Out-Null
    
    # Criar Environment production
    Write-Log "Criando Environment production..."
    gh api --method PUT "repos/FlavinhoZero/$repo/environments/production" 2>&1 | Out-Null
    gh variable set AWS_ACCOUNT_ID --env production --repo "FlavinhoZero/$repo" --body "$AWSAccountId" 2>&1 | Out-Null
    gh variable set TF_VAR_region --env production --repo "FlavinhoZero/$repo" --body $Region 2>&1 | Out-Null
    
    Write-Log "Environments configurados para $repo"
}

Write-Log "========================================="
Write-Log "sync-environments.ps1 concluído!"
Write-Log "========================================="
