output "frontend_url" {
  value       = "https://${azurerm_linux_web_app.frontend.default_hostname}"
  description = "The URL of the frontend Web App."
}

output "backend_url" {
  value       = "https://${azurerm_linux_web_app.backend.default_hostname}"
  description = "The URL of the backend Web App."
}

output "log_analytics_workspace_name" {
  value       = azurerm_log_analytics_workspace.law.name
  description = "The name of the Log Analytics Workspace."
}
