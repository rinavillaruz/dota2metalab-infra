output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL — used by the federated identity credentials above (the Workload Identity equivalent of IRSA's trust policy)"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "models_storage_account" {
  description = "Storage account name for model artifacts (S3 bucket equivalent)"
  value       = azurerm_storage_account.models.name
}

output "models_identity_client_id" {
  description = "Client ID of the user-assigned identity for model storage access — set this as an annotation on the dota2metalab-api / dota2metalab-trainer service accounts (azure.workload.identity/client-id)"
  value       = azurerm_user_assigned_identity.models.client_id
}

output "kube_host" {
  value     = azurerm_kubernetes_cluster.this.kube_config.0.host
  sensitive = true
}
