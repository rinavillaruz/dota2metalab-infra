provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

provider "azuread" {}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.this.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate)
  }
}

# Using kube_config (the local-account kubeconfig AKS issues automatically)
# rather than a static long-lived token, for the same reason the EKS
# module uses `aws eks get-token` via exec: avoid long-lived credentials
# in state/CI where possible. Note: kube_admin_config (the alternative)
# only gets populated when Azure AD RBAC is enabled on the cluster
# (admin_group_object_ids) — since AAD RBAC is off by default here,
# kube_config is what's actually available. AKS's closer equivalent of
# AWS's exec-based token plugin is Azure AD + kubelogin, but that
# requires the kubelogin binary in CI. kube_config is the standard
# bootstrap-time approach and is fine for Terraform-managed cluster
# setup; if you enable admin_group_object_ids later for proper Azure AD
# RBAC, day-to-day human kubectl access should go through that instead
# of this local-account config.
provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.this.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate)
  load_config_file       = false
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "azurerm_client_config" "current" {}

locals {
  tags = {
    Project     = "dota2metalab"
    ManagedBy   = "terraform"
    Environment = "shared"
    Team        = "personal"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${var.cluster_name}-rg"
  location = var.location
  tags     = local.tags
}

# --- Networking ------------------------------------------------------------
# Equivalent of the terraform-aws-modules/vpc module block. Azure CNI means
# pods draw real IPs from this subnet, not a separate overlay range, so
# it's sized generously (same reasoning as sizing VPC CNI secondary ranges
# on EKS).

resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.10.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "${var.cluster_name}-aks-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.0.0/20"]
}

# --- AKS cluster -------------------------------------------------------------
# Equivalent of the terraform-aws-modules/eks module block.

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.cluster_version

  # Equivalent of module.eks's OIDC provider + IRSA on EKS: lets pods
  # assume Azure AD identities via federated credentials instead of
  # hardcoded secrets. See the workload identity block below, which plays
  # the same role as ebs_csi_irsa / s3_models_irsa on the EKS side.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                        = "main"
    temporary_name_for_rotation = "maintemp"
    vm_size                     = var.node_vm_size
    vnet_subnet_id              = azurerm_subnet.aks.id
    node_count                  = var.node_count
    auto_scaling_enabled        = true
    min_count                   = var.min_node_count
    max_count                   = var.max_node_count
    os_disk_size_gb             = 128
    tags                        = local.tags
  }

  # Once auto_scaling_enabled is true, the AKS autoscaler owns the actual
  # node count and it will drift from var.node_count as it scales up/down.
  # Without this, every apply tries to force it back to node_count and
  # the API rejects the change. node_count above still sets the count at
  # initial cluster creation.
  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure" # Azure CNI, not kubenet - real VNet IP per pod
    network_policy    = "azure"
    load_balancer_sku = "standard"
    service_cidr      = "10.20.0.0/24"
    dns_service_ip    = "10.20.0.10"
  }

  # Azure AD RBAC for human kubectl access, separate from the
  # kube_config Terraform uses to bootstrap the cluster above.
  dynamic "azure_active_directory_role_based_access_control" {
    for_each = length(var.admin_group_object_ids) > 0 ? [1] : []
    content {
      admin_group_object_ids = var.admin_group_object_ids
      azure_rbac_enabled     = true
    }
  }

  tags = local.tags
}

# installs argocd
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.11"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [file(abspath("${path.module}/../../deploy/argocd/values.yaml"))]

  depends_on = [azurerm_kubernetes_cluster.this]
}

# installs nginx
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "controller.config.allow-snippet-annotations"
    value = "true"
  }

  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false" # disable the webhook that's blocking snippets
  }

  # Azure LB's default HTTP health probe hits "/" with no Host header,
  # which nginx-ingress answers with 404 (no matching Ingress host) -
  # Azure requires a literal 200, so the probe was marking the backend
  # Down and silently dropping all inbound traffic (root cause of the
  # 522s). Point the probe at nginx's dedicated healthz endpoint instead,
  # which always returns 200 regardless of Host header.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
    value = "/healthz"
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

resource "kubectl_manifest" "argocd_root_app" {
  yaml_body  = file(abspath("${path.module}/../../argocd-apps-aks/root-app.yaml"))
  depends_on = [helm_release.argocd]
}

resource "kubectl_manifest" "argocd_ingress" {
  yaml_body = file(abspath("${path.module}/../../deploy/argocd/argocd-ingress.yaml"))

  depends_on = [helm_release.argocd]
}

resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name = azurerm_kubernetes_cluster.this.name
  }

  provisioner "local-exec" {
    command = "az aks get-credentials --name ${azurerm_kubernetes_cluster.this.name} --resource-group ${azurerm_resource_group.this.name} --overwrite-existing"
  }

  depends_on = [azurerm_kubernetes_cluster.this]
}

# Cloudflare load balancer
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.this.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate)
}

data "kubernetes_service_v1" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}

# Azure's standard LoadBalancer SKU hands back a static public IP, not a
# DNS hostname the way AWS's NLB/ALB does - so unlike the EKS version,
# these become A records instead of CNAMEs. Written to handle either case
# in case that ever changes (e.g. if a DNS label annotation is added).
locals {
  ingress_hostname_raw   = try(data.kubernetes_service_v1.ingress_nginx.status.0.load_balancer.0.ingress.0.hostname, null)
  ingress_hostname       = local.ingress_hostname_raw != null && local.ingress_hostname_raw != "" ? local.ingress_hostname_raw : null
  ingress_ip             = try(data.kubernetes_service_v1.ingress_nginx.status.0.load_balancer.0.ingress.0.ip, null)
  ingress_record_type    = local.ingress_hostname != null ? "CNAME" : "A"
  ingress_record_content = local.ingress_hostname != null ? local.ingress_hostname : local.ingress_ip
}

resource "cloudflare_record" "root" {
  zone_id         = var.cloudflare_zone_id
  name            = "@"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "staging" {
  zone_id         = var.cloudflare_zone_id
  name            = "staging"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "argocd" {
  zone_id         = var.cloudflare_zone_id
  name            = "argocd"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

# --- New: DNS for the AKS-specific secondary deployment ---------------------
# dota2metalab.com / staging.dota2metalab.com stay pointed at EKS (unchanged
# above). These give the AKS deployment its own, separate hostnames so the
# two clusters run as independent copies rather than sharing traffic.

resource "cloudflare_record" "azure_app" {
  zone_id         = var.cloudflare_zone_id
  name            = "azure"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "azure_staging" {
  zone_id         = var.cloudflare_zone_id
  name            = "azure-staging"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

# =============================================================
# Blob Storage — Model Storage
# Azure equivalent of the S3 model bucket. Same reasoning as the EKS
# side: shared, versioned, encrypted storage for ML model artifacts
# across pods/environments, avoiding the WaitForFirstConsumer PVC
# deadlock you hit with EBS.
# =============================================================

resource "azurerm_storage_account" "models" {
  name                     = "dota2metalabmodels" # must be globally unique, lowercase, no dashes
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Encrypted at rest by default (Microsoft-managed keys) - Azure Storage
  # equivalent of the AES256 SSE config on the S3 bucket.
  min_tls_version = "TLS1_2"

  blob_properties {
    versioning_enabled = true # rollback to previous model versions, same as S3 versioning
  }

  public_network_access_enabled = false # models are internal assets only

  tags = local.tags
}

resource "azurerm_storage_container" "models" {
  name                  = "models"
  storage_account_id    = azurerm_storage_account.models.id
  container_access_type = "private"
}

# --- Workload Identity — model storage access -------------------------------
# Equivalent of s3_models_irsa on EKS: lets the API and trainer pods read/
# write model blobs without hardcoded credentials. Instead of an IAM role
# trust policy scoped to OIDC subjects (IRSA), Azure uses a user-assigned
# managed identity + one federated credential per (namespace, service
# account) pair, trusting the AKS OIDC issuer.

resource "azurerm_user_assigned_identity" "models" {
  name                = "dota2metalab-models-identity"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "models_blob_access" {
  scope                = azurerm_storage_account.models.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.models.principal_id
}

locals {
  # Mirrors the namespace_service_accounts list on s3_models_irsa
  model_workload_identity_subjects = {
    "dev-api"         = "system:serviceaccount:dota2metalab-dev:dota2metalab-api"
    "staging-api"     = "system:serviceaccount:dota2metalab-staging:dota2metalab-api"
    "prod-api"        = "system:serviceaccount:dota2metalab-prod:dota2metalab-api"
    "dev-trainer"     = "system:serviceaccount:dota2metalab-dev:dota2metalab-trainer"
    "staging-trainer" = "system:serviceaccount:dota2metalab-staging:dota2metalab-trainer"
    "prod-trainer"    = "system:serviceaccount:dota2metalab-prod:dota2metalab-trainer"
  }
}

resource "azurerm_federated_identity_credential" "models" {
  for_each = local.model_workload_identity_subjects

  name                      = "dota2metalab-models-${each.key}"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  user_assigned_identity_id = azurerm_user_assigned_identity.models.id
  subject                   = each.value
}

# --- Metrics server -----------------------------------------------------
# Unlike EKS, AKS installs metrics-server in kube-system out of the box.
# No helm_release needed here — attempting to install it via Helm
# conflicts with the pre-existing, AKS-managed one. Verify with:
#   kubectl get deployment metrics-server -n kube-system
#   kubectl top nodes

# --- Cluster autoscaling -----------------------------------------------------
# Unlike EKS, no separate Cluster Autoscaler Helm chart + IAM policy + IRSA
# role is needed here: AKS's node pool autoscaler is native
# (auto_scaling_enabled / min_count / max_count on default_node_pool
# above), managed directly by the AKS control plane. One less moving part
# to run and patch versions on - worth calling out as a genuine
# operational simplification vs. the EKS setup.

resource "azurerm_consumption_budget_resource_group" "monthly" {
  name              = "monthly-total"
  resource_group_id = azurerm_resource_group.this.id

  amount     = 50
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.budget_alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.budget_alert_email]
  }

  lifecycle {
    ignore_changes = [time_period.0.start_date]
  }
}

# Renamed from "managed-premium" to "managed-premium-v2": the
# StorageClass's `parameters` block is immutable once created, so
# reapplying the original name kept failing with
# "updates to parameters are forbidden". This creates a fresh
# StorageClass instead of patching the old one in place.
#
# NOTE: update storageClassName references in Helm values / PVC
# templates (e.g. Prometheus/Grafana persistence, ArgoCD app manifests)
# from "managed-premium" to "managed-premium-v2". Once nothing
# references the old class, delete it out of band with:
#   kubectl delete storageclass managed-premium
resource "kubectl_manifest" "managed_premium_storage_class" {
  yaml_body = <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-premium-v2
  annotations:
    argocd.argoproj.io/sync-wave: "0"
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
YAML

  depends_on = [azurerm_kubernetes_cluster.this]
}

resource "helm_release" "prometheus" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [
    file(abspath("${path.module}/../../deploy/prometheus/values.yaml")),
    yamlencode({
      grafana = {
        adminPassword = var.grafana_password
      }
      alertmanager = {
        config = {
          global = {
            slack_api_url = var.slack_webhook_url
          }
        }
      }
    })
  ]

  depends_on = [azurerm_kubernetes_cluster.this]
}

resource "cloudflare_record" "grafana" {
  zone_id         = var.cloudflare_zone_id
  name            = "grafana"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "prometheus" {
  zone_id         = var.cloudflare_zone_id
  name            = "prometheus"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}

resource "kubectl_manifest" "dota2metalab_alerts" {
  yaml_body  = file(abspath("${path.module}/../../deploy/prometheus/alerts.yaml"))
  depends_on = [helm_release.prometheus]
}

resource "cloudflare_record" "alertmanager" {
  zone_id         = var.cloudflare_zone_id
  name            = "alertmanager"
  content         = local.ingress_record_content
  type            = local.ingress_record_type
  proxied         = true
  allow_overwrite = true
}
