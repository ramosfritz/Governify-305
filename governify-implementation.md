# Governify: Azure CLI Deployment & Design Guide

This document describes how to deploy, configure, and manage identity, governance, and monitoring solutions for a multi-tier web application using the Azure CLI.

---

## 1. Environment & Infrastructure Setup

Run the following commands to provision the base resource group, App Service plan, frontend, backend, and SQL database:

```powershell
# 1. Variables
$resourceGroup = "rg-governify"
$location = "eastus"
$frontendApp = "web-governify-fe-unique"
$backendApp = "web-governify-be-unique"
$sqlServer = "sql-governify-srv-unique"
$sqlDb = "db-governify"
$workspaceName = "law-governify"
$appInsightsName = "insights-governify"

# 2. Resource Group
az group create --name $resourceGroup --location $location --tags Environment=Production Project=Governify

# 3. App Service Plan
az appservice plan create --name plan-governify --resource-group $resourceGroup --location $location --sku B1 --is-linux

# 4. Frontend & Backend Web Apps
az webapp create --name $frontendApp --plan plan-governify --resource-group $resourceGroup --runtime "NODE:18-lts"
az webapp create --name $backendApp --plan plan-governify --resource-group $resourceGroup --runtime "NODE:18-lts"

# 5. Azure SQL Database
az sql server create --name $sqlServer --resource-group $resourceGroup --location $location --admin-user "dbadmin" --admin-password "P@ssw0rd1234!!"
az sql db create --name $sqlDb --resource-group $resourceGroup --server $sqlServer --service-objective S0

# 6. Allow Access to Azure Services
az sql server firewall-rule create --resource-group $resourceGroup --server $sqlServer --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0
```

---

## 2. Authentication Integration (Microsoft Entra ID / Azure AD)

Secure the web applications using App Service Authentication (Easy Auth) via the CLI:

```powershell
# 1. Create App Registration for Frontend
$feAppReg = az ad app create --display-name "Governify-Frontend" --web-redirect-uris "https://${frontendApp}.azurewebsites.net/.auth/login/aad/callback" | ConvertFrom-Json
$feClientId = $feAppReg.appId

# 2. Configure Easy Auth on Frontend App Service
az webapp auth update --resource-group $resourceGroup --name $frontendApp --enabled true --action LoginWithAzureActiveDirectory --aad-client-id $feClientId --aad-token-issuer-url "https://sts.windows.net/$(az account show --query tenantId -o tsv)/v2.0"
```

---

## 3. Governance (Azure Policy & Blueprints)

Ensure policy compliance across the subscription:

```powershell
# 1. Add Blueprint Extension
az extension add --name blueprint

# 2. Define Custom Enforce-Tag Policy Rules
# This JSON denies creation of resources that don't have the Environment tag
$policyRule = '{
    "if": {
        "field": "tags[Environment]",
        "exists": "false"
    },
    "then": {
        "effect": "deny"
    }
}'

az policy definition create --name "enforce-environment-tag" --rules $policyRule --display-name "Enforce Environment Tag"

# 3. Create and Assign Blueprint
az blueprint create --name "bp-governify" --target-scope subscription --display-name "Governify Governance Blueprint"
az blueprint artifact policy create --blueprint-name "bp-governify" --artifact-name "enforce-tag-artifact" --policy-definition-id "/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.Authorization/policyDefinitions/enforce-environment-tag"
```

---

## 4. Diagnostics & Logs (Azure Monitor & Log Analytics)

Capture and centralize monitoring telemetry:

```powershell
# 1. Create Log Analytics Workspace
az monitor log-analytics workspace create --resource-group $resourceGroup --workspace-name $workspaceName

# 2. Create Application Insights Component
az monitor app-insights component create --app $appInsightsName --location $location --resource-group $resourceGroup --workspace $workspaceName

# 3. Fetch Workspace IDs
$workspaceId = az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $workspaceName --query id -o tsv
$connString = az monitor app-insights component show --app $appInsightsName --resource-group $resourceGroup --query connectionString -o tsv

# 4. Set Application Insights connection on Web Apps
az webapp config appsettings set --resource-group $resourceGroup --name $frontendApp --settings APPLICATIONINSIGHTS_CONNECTION_STRING="$connString"
az webapp config appsettings set --resource-group $resourceGroup --name $backendApp --settings APPLICATIONINSIGHTS_CONNECTION_STRING="$connString"

# 5. Enable Diagnostic Settings for App Services and SQL DB
az monitor diagnostic-settings create --name "app-service-diagnostics" --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$frontendApp" --workspace $workspaceId --logs '[{"category":"AppServiceConsoleLogs","enabled":true},{"category":"AppServiceHTTPLogs","enabled":true}]'
az monitor diagnostic-settings create --name "app-service-diagnostics" --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$backendApp" --workspace $workspaceId --logs '[{"category":"AppServiceConsoleLogs","enabled":true},{"category":"AppServiceHTTPLogs","enabled":true}]'
az monitor diagnostic-settings create --name "sql-db-diagnostics" --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resourceGroup/providers/Microsoft.Sql/servers/$sqlServer/databases/$sqlDb" --workspace $workspaceId --logs '[{"category":"SQLSecurityAuditEvents","enabled":true}]' --metrics '[{"category":"AllMetrics","enabled":true}]'
```

---

## 5. Verification & Testing

Verify that resources are properly secured, compliant, and emitting telemetry:

### A. Tag Enforcement Test (Policy)
Attempt to create a standard storage account without specifying any tags. This should fail:
```powershell
az storage account create --name "noncompliantstore" --resource-group rg-governify --location eastus --sku Standard_LRS
```

### B. Application Telemetry Query (KQL)
Query the logs inside the Log Analytics Workspace:
```kusto
AppServiceConsoleLogs
| where Message contains "Governify"
| order by TimeGenerated desc
| take 20
```
