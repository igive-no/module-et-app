output "azurerm_key_vault" {
  value = azurerm_key_vault.kv
}

output "azurerm_resource_group" {
  value = azurerm_resource_group.rg
}

output "identity" {
  value = azurerm_user_assigned_identity.identity
}