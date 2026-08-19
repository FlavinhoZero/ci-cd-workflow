# sync-environments.ps1 - Script para criar Environments nos repositórios do projeto

<#
.SYNOPSIS
    Script para criar Environments test/production em múltiplos repositórios.

.DESCRIPTION
    Este script cria os Environments test e production nos repositórios do projeto,
    configurando as variáveis necessárias.

    IMPORTANTE: A lista de repositórios é lida de 'repos-config.local.json' (NÃO versionado).
    Não há nomes de repositórios internos hardcoded neste script.

.PARAMETER AWSAccountId
    ID da conta AWS a ser configurada nas variáveis de ambiente.

.PARAMETER Region
    Região AWS padrão (padrão: sa-east-1).

.PARAMETER Reviewer
    Login do reviewer obrigatório para o ambiente production.

.EXAMPLE
    .\sync-environments.ps1 -AWSAccountId "<AWS_ACCOUNT_ID>" -Reviewer "<OWNER>"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AWSAccountId,
    [string]$Region = "sa-east-1",
    [string]$Reviewer = ""
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
Write-Log "Iniciando sync-environments.ps1"
Write-Log "AWS Account ID: $AWSAccountId"
Write-Log "Região: $Region"
Write-Log "Reviewer: $Reviewer"
Write-Log "========================================="

foreach ($repo in $Repos) {
    Write-Log "Configurando Environments para $repo..."
    
    # Criar Environment test
    Write-Log "Criando Environment test..."
    gh api --method PUT "repos/$Owner/$repo/environments/test" 2>&1 | Out-Null
    gh variable set AWS_ACCOUNT_ID --env test --repo "$Owner/$repo" --body "$AWSAccountId" 2>&1 | Out-Null
    gh variable set TF_VAR_region --env test --repo "$Owner/$repo" --body $Region 2>&1 | Out-Null
    
    # Criar Environment production
    Write-Log "Criando Environment production..."
    gh api --method PUT "repos/$Owner/$repo/environments/production" 2>&1 | Out-Null
    gh variable set AWS_ACCOUNT_ID --env production --repo "$Owner/$repo" --body "$AWSAccountId" 2>&1 | Out-Null
    gh variable set TF_VAR_region --env production --repo "$Owner/$repo" --body $Region 2>&1 | Out-Null
    
    Write-Log "Environments configurados para $repo"
}

Write-Log "========================================="
Write-Log "sync-environments.ps1 concluído!"
Write-Log "========================================="
