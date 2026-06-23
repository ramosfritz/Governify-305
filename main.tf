resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

data "azuread_client_config" "current" {}

# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags = {
    Environment = var.environment
    Project     = "Governify"
  }
}

# 2. Linux App Service Plan (Free F1 SKU)
resource "azurerm_service_plan" "asp" {
  name                = "asp-${var.app_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "F1"
}

# 3. Azure AD App Registration (Easy Auth Identity)
resource "azuread_application" "frontend_app" {
  display_name     = "Governify-Frontend-${var.app_prefix}-${random_string.suffix.result}"
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = ["https://${var.app_prefix}-${random_string.suffix.result}-frontend.azurewebsites.net/.auth/login/aad/callback"]
    implicit_grant {
      access_token_issuance_enabled = true
      id_token_issuance_enabled     = true
    }
  }
}

resource "azuread_application_password" "frontend_secret" {
  application_object_id = azuread_application.frontend_app.object_id
  end_date_relative     = "8760h" # 1 Year expiry
}

# 4. Frontend Linux Web App
resource "azurerm_linux_web_app" "frontend" {
  name                = "${var.app_prefix}-${random_string.suffix.result}-frontend"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.asp.id

  site_config {
    always_on = false
    application_stack {
      node_version = "20-lts"
    }
  }

  app_settings = {
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.insights.connection_string
    "BACKEND_API_URL"                       = "https://${var.app_prefix}-${random_string.suffix.result}-backend.azurewebsites.net"
    "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "true"
  }

  auth_settings {
    enabled          = true
    default_provider = "AzureActiveDirectory"
    active_directory {
      client_id     = azuread_application.frontend_app.client_id
      client_secret = azuread_application_password.frontend_secret.value
      allowed_audiences = [
        "https://${var.app_prefix}-${random_string.suffix.result}-frontend.azurewebsites.net"
      ]
    }
  }
}

# 5. Backend Linux Web App
resource "azurerm_linux_web_app" "backend" {
  name                = "${var.app_prefix}-${random_string.suffix.result}-backend"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.asp.id

  site_config {
    always_on = false
    application_stack {
      node_version = "20-lts"
    }
  }

  app_settings = {
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.insights.connection_string
    "SQL_CONNECTION_STRING"                 = "Server=tcp:${azurerm_mssql_server.sql.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.db.name};User ID=${var.sql_admin_user};Password=${var.sql_admin_password};Encrypt=true;Connection Timeout=30;"
    "TENANT_ID"                             = data.azuread_client_config.current.tenant_id
    "CLIENT_ID"                             = azuread_application.frontend_app.client_id
    "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "true"
  }
}

# 6. SQL Server & SQL Database
resource "azurerm_mssql_server" "sql" {
  name                         = "${var.app_prefix}-${random_string.suffix.result}-sql"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_user
  administrator_login_password = var.sql_admin_password
}

resource "azurerm_mssql_database" "db" {
  name         = "db-governify"
  server_id    = azurerm_mssql_server.sql.id
  sku_name     = "Basic"
  max_size_gb  = 2
}

resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# 7. Log Analytics & Application Insights (Telemetry)
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${var.app_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "insights" {
  name                = "insights-${var.app_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}

# 8. Diagnostics Logs Settings
resource "azurerm_monitor_diagnostic_setting" "fe_diagnostics" {
  name                       = "fe-appservice-diagnostics"
  target_resource_id         = azurerm_linux_web_app.frontend.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "AppServiceConsoleLogs"
  }
  enabled_log {
    category = "AppServiceHTTPLogs"
  }
  metric {
    category = "AllMetrics"
    enabled  = false
  }
}

resource "azurerm_monitor_diagnostic_setting" "be_diagnostics" {
  name                       = "be-appservice-diagnostics"
  target_resource_id         = azurerm_linux_web_app.backend.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "AppServiceConsoleLogs"
  }
  enabled_log {
    category = "AppServiceHTTPLogs"
  }
  metric {
    category = "AllMetrics"
    enabled  = false
  }
}

resource "azurerm_monitor_diagnostic_setting" "sql_diagnostics" {
  name                       = "sql-db-diagnostics"
  target_resource_id         = azurerm_mssql_database.db.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "SQLSecurityAuditEvents"
  }
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# 9. Cloud Governance (Azure Policy definition & assignment)
resource "azurerm_policy_definition" "enforce_env_tag" {
  name         = "enforce-environment-tag"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Enforce Environment Tag"
  description  = "Enforces the presence of the Environment tag on all resources."
  policy_rule  = file("${path.module}/policy-rules.json")
}

resource "azurerm_resource_group_policy_assignment" "assign_enforce_env_tag" {
  name                 = "assign-enforce-tag"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = azurerm_policy_definition.enforce_env_tag.id
}
