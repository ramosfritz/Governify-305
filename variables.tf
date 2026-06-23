variable "location" {
  type        = string
  description = "The Azure region to deploy resources into."
  default     = "centralus"
}

variable "resource_group_name" {
  type        = string
  description = "The name of the resource group."
  default     = "rg-governify-terraform"
}

variable "app_prefix" {
  type        = string
  description = "A prefix used to ensure globally unique names for services."
  default     = "governify"
}

variable "sql_admin_user" {
  type        = string
  description = "The administrator username for the SQL Server."
  default     = "dbadmin"
}

variable "sql_admin_password" {
  type        = string
  description = "The administrator password for the SQL Server. Must be complex."
  default     = "P@ssw0rd1234!!"
  sensitive   = true
}

variable "environment" {
  type        = string
  description = "The environment tag (e.g. Production, Development)."
  default     = "Production"
}
