terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.60.0"
    }
  }
}

data "azurerm_client_config" "current" {
}

# Find the aks cluster for current environment
data "azurerm_resources" "aks" {
  type = "Microsoft.ContainerService/ManagedClusters"
  name = var.aks_name
}

data "azurerm_kubernetes_cluster" "aks-cluster" {
  name                = var.aks_name
  resource_group_name = data.azurerm_resources.aks.resources[0].resource_group_name
}

# Create the identity for the current application
resource "azurerm_user_assigned_identity" "identity" {
  resource_group_name = data.azurerm_resources.aks.resources[0].tags["node-resource-group"]
  location            = var.location
  name                = var.identity_name
}

resource "azurerm_federated_identity_credential" "federated-identity" {
  name                = "fi-${lower(var.environment)}-${var.service_name}"
  resource_group_name = data.azurerm_resources.aks.resources[0].tags["node-resource-group"]
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.aks-cluster.oidc_issuer_url
  subject             = "system:serviceaccount:${var.environment == "test" ? "et-test" : "et-prod"}:sa-${var.service_name}"
  parent_id           = azurerm_user_assigned_identity.identity.id
}

resource "azurerm_federated_identity_credential" "additional-identities" {
  for_each            = toset(var.federated_identities)
  name                = "fi-${lower(var.environment)}-${var.service_name}-${each.value}"
  resource_group_name = data.azurerm_resources.aks.resources[0].tags["node-resource-group"]
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.aks-cluster.oidc_issuer_url
  subject             = "system:serviceaccount:${var.environment == "test" ? "et-test" : "et-prod"}:sa-${each.value}"
  parent_id           = azurerm_user_assigned_identity.identity.id
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_key_vault" "kv" {
  name                = "${var.service_name}-${lower(var.environment)}-${var.kv_name_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "standard"
  tenant_id           = data.azurerm_client_config.current.tenant_id
}

# Key Vault Access Policy - Terraform Service Principal
resource "azurerm_key_vault_access_policy" "policy-sp-terraform" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Delete",
    "Set",
    "Purge",
    "Recover",
    "Restore"
  ]
}

#system developers
resource "azurerm_key_vault_access_policy" "admin" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = "d49bbab7-15fb-45a9-950f-38a0d8b3210e"

  secret_permissions = [
    "Get",
    "List",
    "Delete",
    "Set",
  ]

  certificate_permissions = [
    "Update",
    "List",
    "ListIssuers",
    "Get",
    "GetIssuers",
    "Delete",
    "DeleteIssuers",
    "Purge",
    "Recover",
    "Restore",
    "Import"
  ]

  key_permissions = [
    "Create",
    "Decrypt",
    "Encrypt",
    "Delete",
    "Get",
    "List",
    "Update",
    "Import",
    "Verify",
    "Purge",
    "Recover",
    "Restore",
    "Sign",
    "UnwrapKey",
    "GetRotationPolicy",
    "SetRotationPolicy",
    "Backup"
  ]
}

# Key Vault Access Policy - Azure DevOps Service Principal
resource "azurerm_key_vault_access_policy" "policy-sp-devops" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.devops_oid

  secret_permissions = [
    "Get",
    "List",
    "Delete",
    "Set",
  ]
}

# Key Vault Access Policy - Service Identity
resource "azurerm_key_vault_access_policy" "policy-serviceidentity" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.identity.principal_id

  secret_permissions = [
    "Get",
    "List"
  ]

  certificate_permissions = [
    "Get",
    "GetIssuers",
    "ListIssuers",
    "List"
  ]

  key_permissions = [
    "Get",
    "List",
    "UnwrapKey",
    "GetRotationPolicy",
    "Decrypt",
    "GetRotationPolicy",
  ]
}

data "azurerm_log_analytics_workspace" "analytics" {
  name                = "et-loganalytics"
  resource_group_name = "et-log-analytics"
}

# Application Insights
resource "azurerm_application_insights" "appinsights" {
  name                = "et-${var.service_name}-${lower(var.environment)}-ai"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = var.app_type
  workspace_id        = data.azurerm_log_analytics_workspace.analytics.id
}

# Key Vault Secret (Application insights Instrumentation Key)
resource "azurerm_key_vault_secret" "appinssecret" {
  name         = "ApplicationInsights--InstrumentationKey"
  key_vault_id = azurerm_key_vault.kv.id
  value        = azurerm_application_insights.appinsights.instrumentation_key

  depends_on = [azurerm_key_vault_access_policy.policy-sp-terraform]
}
