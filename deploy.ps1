<#
.SYNOPSIS
    Deploys the Governify identity, governance, and monitoring solution to Azure using Azure CLI.
.DESCRIPTION
    Prerequisites:
      1. Azure CLI installed (https://aka.ms/installazurecliwindows)
      2. Run `az login` and select active subscription.
      3. Run this script in PowerShell.
#>

[CmdletBinding()]
param (
    [string]$ResourceGroupName = "rg-governify-central",
    [string]$Location = "centralus",
    [string]$AppPrefix = "governify$(Get-Random -Minimum 1000 -Maximum 9999)",
    [string]$SqlAdminUser = "dbadmin",
    [string]$SqlAdminPassword = "P@ssw0rd1234!!$(Get-Random -Minimum 10 -Maximum 99)",
    [string]$Environment = "Production"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " STARTING GOVERNIFY AZURE DEPLOYMENT     " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Configured parameters:"
Write-Host "  - Resource Group: $ResourceGroupName"
Write-Host "  - Location:       $Location"
Write-Host "  - App Name Prefix: $AppPrefix"
Write-Host "  - SQL Admin:      $SqlAdminUser"
Write-Host "  - SQL Password:   [SECURE]"
Write-Host "========================================="

# 1. Verify az cli login
Write-Host "[1/6] Checking Azure CLI login status..." -ForegroundColor Yellow
$currentSub = az account show --query name -o tsv 2>$null
if (-not $currentSub) {
    Write-Error "Not logged into Azure CLI. Please run 'az login' before running this script."
}
$subscriptionId = az account show --query id -o tsv
Write-Host "Logged in to subscription: $currentSub ($subscriptionId)" -ForegroundColor Green

# 2. Provision Resources
Write-Host "[2/6] Provisioning core Azure resources..." -ForegroundColor Yellow
Write-Host "Creating Resource Group: $ResourceGroupName..."
az group create --name $ResourceGroupName --location $Location --tags Environment=$Environment Project=Governify --query "properties.provisioningState" -o tsv

Write-Host "Creating Linux App Service Plan..."
$aspName = "asp-$AppPrefix"
az appservice plan create --name $aspName --resource-group $ResourceGroupName --location $Location --sku F1 --is-linux --query "provisioningState" -o tsv

Write-Host "Creating Frontend Web App..."
$feAppName = "$AppPrefix-frontend"
az webapp create --name $feAppName --plan $aspName --resource-group $ResourceGroupName --runtime "NODE:22-lts" --query "state" -o tsv

Write-Host "Creating Backend API App..."
$beAppName = "$AppPrefix-backend"
az webapp create --name $beAppName --plan $aspName --resource-group $ResourceGroupName --runtime "NODE:22-lts" --query "state" -o tsv

Write-Host "Creating Azure SQL Database..."
$sqlServerName = "$AppPrefix-sql"
$dbName = "db-governify"
az sql server create --name $sqlServerName --resource-group $ResourceGroupName --location $Location --admin-user $SqlAdminUser --admin-password $SqlAdminPassword --query "state" -o tsv
az sql db create --name $dbName --resource-group $ResourceGroupName --server $sqlServerName --service-objective S0 --query "status" -o tsv

Write-Host "Adding database firewall rule for internal Azure traffic..."
az sql server firewall-rule create --resource-group $ResourceGroupName --server $sqlServerName --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --query "name" -o tsv

# 3. Setup Authentication (Microsoft Entra ID)
Write-Host "[3/6] Configuring Microsoft Entra ID Authentication..." -ForegroundColor Yellow
$tenantId = az account show --query tenantId -o tsv

Write-Host "Registering Frontend App Registration in Entra ID..."
$feAppReg = az ad app create --display-name "Governify-Frontend-$AppPrefix" --web-redirect-uris "https://$feAppName.azurewebsites.net/.auth/login/aad/callback" | ConvertFrom-Json
$feClientId = $feAppReg.appId

Write-Host "Generating client secret for AAD App..."
$clientSecret = az ad app credential reset --id $feClientId --append --query "password" -o tsv

Write-Host "Configuring App Service Easy Auth on Frontend..."
az webapp auth update --resource-group $ResourceGroupName --name $feAppName --enabled true --action LoginWithAzureActiveDirectory --aad-client-id $feClientId --aad-client-secret $clientSecret --aad-token-issuer-url "https://sts.windows.net/$tenantId/" --query "enabled" -o tsv

# 4. Setup Governance (Policies & Blueprints)
Write-Host "[4/6] Registering Governance Policies..." -ForegroundColor Yellow

# Create Azure Policy definition using our local JSON rule
$policyDefinitionName = "enforce-environment-tag-$AppPrefix"
Write-Host "Registering Tag Enforce Azure Policy: $policyDefinitionName..."
az policy definition create --name $policyDefinitionName --rules "policy-rules.json" --display-name "Enforce Environment Tag" --description "Enforces Environment tagging on resources." --query "name" -o tsv

# Deploy Blueprint (Legacy / Blueprint Extension CLI)
Write-Host "Registering Azure Blueprint (using az blueprint extension)..."
az extension add --name blueprint --yes --only-show-errors 2>$null
$blueprintName = "bp-governify-$AppPrefix"

az blueprint create --name $blueprintName --target-scope subscription --display-name "Governify Governance Blueprint" --description "Blueprint enforcing environment policy and tags." --query "name" -o tsv

$policyDefinitionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyDefinitions/$policyDefinitionName"
az blueprint artifact policy create --blueprint-name $blueprintName --artifact-name "enforce-tag-artifact" --policy-definition-id $policyDefinitionId --query "name" -o tsv

# 5. Setup Logging & Diagnostics (Azure Monitor & Log Analytics)
Write-Host "[5/6] Deploying Log Analytics Workspace & App Insights..." -ForegroundColor Yellow
$lawName = "law-$AppPrefix"
$appInsightsName = "insights-$AppPrefix"

Write-Host "Creating Log Analytics Workspace: $lawName..."
az monitor log-analytics workspace create --resource-group $ResourceGroupName --workspace-name $lawName --query "provisioningState" -o tsv
$lawResourceId = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $lawName --query id -o tsv

Write-Host "Creating Application Insights: $appInsightsName..."
az monitor app-insights component create --app $appInsightsName --location $Location --resource-group $ResourceGroupName --workspace $lawName --query "provisioningState" -o tsv
$connString = az monitor app-insights component show --app $appInsightsName --resource-group $ResourceGroupName --query connectionString -o tsv

# Configure Application Strings
Write-Host "Setting Environment Application Settings on Frontend App..."
az webapp config appsettings set --resource-group $ResourceGroupName --name $feAppName --settings APPLICATIONINSIGHTS_CONNECTION_STRING="$connString" BACKEND_API_URL="https://$beAppName.azurewebsites.net" --query "[?name=='BACKEND_API_URL'].value" -o tsv

Write-Host "Setting Environment Application Settings on Backend App..."
$sqlConnStr = "Server=tcp:${sqlServerName}.database.windows.net,1433;Database=${dbName};User ID=$SqlAdminUser;Password=$SqlAdminPassword;Encrypt=true;Connection Timeout=30;"
az webapp config appsettings set --resource-group $ResourceGroupName --name $beAppName --settings APPLICATIONINSIGHTS_CONNECTION_STRING="$connString" SQL_CONNECTION_STRING="$sqlConnStr" TENANT_ID="$tenantId" CLIENT_ID="$feClientId" --query "[?name=='CLIENT_ID'].value" -o tsv

# Enable Web App Diagnostic settings to route to Log Analytics
Write-Host "Linking Frontend App Service Diagnostics to Log Analytics..."
az monitor diagnostic-settings create --name "fe-appservice-diagnostics" --resource "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$feAppName" --workspace $lawResourceId --logs '[{"category":"AppServiceConsoleLogs","enabled":true},{"category":"AppServiceHTTPLogs","enabled":true}]' --query "name" -o tsv

Write-Host "Linking Backend App Service Diagnostics to Log Analytics..."
az monitor diagnostic-settings create --name "be-appservice-diagnostics" --resource "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$beAppName" --workspace $lawResourceId --logs '[{"category":"AppServiceConsoleLogs","enabled":true},{"category":"AppServiceHTTPLogs","enabled":true}]' --query "name" -o tsv

Write-Host "Linking Azure SQL Database Diagnostics to Log Analytics..."
az monitor diagnostic-settings create --name "sql-db-diagnostics" --resource "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Sql/servers/$sqlServerName/databases/$dbName" --workspace $lawResourceId --logs '[{"category":"SQLSecurityAuditEvents","enabled":true}]' --metrics '[{"category":"AllMetrics","enabled":true}]' --query "name" -o tsv

# 6. Deployment Output Summary
Write-Host "=========================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETED SUCCESSFULLY       " -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host "Frontend URL: https://$feAppName.azurewebsites.net" -ForegroundColor Cyan
Write-Host "Backend URL:  https://$beAppName.azurewebsites.net" -ForegroundColor Cyan
Write-Host "Log Analytics Workspace Name: $lawName" -ForegroundColor Cyan
Write-Host "========================================="
