variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "swedencentral"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "dota2metalab"
}

variable "cluster_version" {
  description = "Kubernetes version. Leave null to use AKS's current default GA version for the region — avoids hardcoding a version that later ages out of standard support (e.g. 1.30 did, as of mid-2026, and requires opting into paid LTS to keep using). Check `az aks get-versions --location <region> -o table` if you want to pin one explicitly."
  type        = string
  default     = null
}

variable "node_vm_size" {
  description = "VM size for the default node pool. Standard_D2s_v3 (2vCPU/8GB) is the closest match to your EKS t3.medium (2vCPU/4GB)."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "min_node_count" {
  description = "AKS autoscaler minimum (native to the node pool, unlike EKS where you had to run a separate Cluster Autoscaler deployment + IRSA role for this)"
  type        = number
  default     = 1
}

variable "max_node_count" {
  type    = number
  default = 4
}

variable "admin_group_object_ids" {
  description = "Azure AD group object IDs to grant AKS cluster-admin via Azure AD RBAC. Leave empty to skip AAD RBAC and rely on kube_admin_config only."
  type        = list(string)
  default     = []
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type = string
}

variable "grafana_password" {
  type      = string
  sensitive = true
}

variable "slack_webhook_url" {
  type      = string
  sensitive = true
}

variable "budget_alert_email" {
  description = "Email for Azure budget threshold alerts"
  type        = string
}
