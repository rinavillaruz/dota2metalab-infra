# dota2metalab — AKS (mirrors infrastructure/terraform/eks)

This is a resource-for-resource mirror of your EKS `main.tf`: same VPC/AKS
shape, same ArgoCD + nginx-ingress + Prometheus stack, same Cloudflare DNS,
same model storage + workload identity pattern, same budget alerting.
Separate state, separate provider block, doesn't touch anything on the AWS
side.

## Where this goes

Place this folder at `infrastructure/terraform/aks/`, alongside your existing
`infrastructure/terraform/eks/`. The relative paths in `main.tf`
(`../../deploy/argocd/values.yaml`, `../../argocd-apps/root-app.yaml`, etc.)
assume the same directory depth as the EKS module — if you put it anywhere
else, those `file()` calls will break.

## What's identical to EKS

- ArgoCD (same chart, same version, same values.yaml, same root-app.yaml)
- nginx-ingress (same chart, same snippet-annotation settings)
- metrics-server (still not bundled by AKS by default, same as EKS)
- kube-prometheus-stack (same chart, same values.yaml, same alerts.yaml)
- Cloudflare DNS records (root, staging, argocd, grafana, prometheus, alertmanager)
- Tagging convention (Project/ManagedBy/Environment/Team)
- Budget alerting at 80% actual / 100% forecasted

## What's different, and why

| Concern | EKS | AKS (this module) |
|---|---|---|
| Pod networking | VPC CNI | Azure CNI (`network_plugin = "azure"`) — real VNet IP per pod, same tradeoff |
| Workload → cloud API access | IRSA (OIDC + IAM role trust policy) | Workload Identity (OIDC + federated identity credential per namespace/SA) |
| Model storage | S3 bucket + versioning + SSE | Storage Account + Blob container + blob versioning |
| Cluster autoscaling | Separate Cluster Autoscaler Helm chart + IAM policy + IRSA role | **Native** — just `auto_scaling_enabled`/`min_count`/`max_count` on the node pool. One less thing to run. |
| Block storage class | `gp3` via EBS CSI | `managed-premium` via Azure Disk CSI |
| DNS record type for ingress LB | CNAME (ALB/NLB hands back a hostname) | **A record** (Azure standard LB hands back a static IP, not a hostname) |
| Terraform-time cluster auth | `aws eks get-token` exec plugin | `kube_admin_config` (short-lived admin cert) — see note in `main.tf` on why this isn't a 1:1 swap |
| Cost controls | AWS Budgets + SNS topic | `azurerm_consumption_budget_resource_group` with direct email notification |

The autoscaler simplification and the CNAME→A record difference are both
good, concrete "here's what I learned porting this to Azure" points for
interviews — they're not obvious until you actually build it.

## Prereqs

```bash
az login
az account set --subscription "<your-subscription-id>"
terraform -version   # >= 1.5
```

## Steps

```bash
cd infrastructure/terraform/aks

cp terraform.tfvars.example terraform.tfvars
# fill in: subscription_id, cloudflare_api_token, cloudflare_zone_id,
# grafana_password, slack_webhook_url, budget_alert_email

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Known things to check before/after apply

- **Storage account name** (`dota2metalabmodels`) must be globally unique
  across *all* of Azure, not just your subscription. If `terraform apply`
  fails on that resource, append a short suffix and re-apply.
- **`argocd/values.yaml` and `prometheus/values.yaml`** were written for
  EKS — check them for anything AWS-specific (e.g. ALB annotations, EBS
  storageClassName references, IRSA service-account annotations). You'll
  likely need an Azure override file or a couple of conditional values
  once you actually deploy workloads, similar to what you'll hit in
  Phase 2 of the AKS rollout.
- **Service account annotations**: once you deploy the API/trainer pods,
  annotate their service accounts with
  `azure.workload.identity/client-id: <models_identity_client_id output>`
  and label the pod spec `azure.workload.identity/use: "true"` — this is
  the Workload Identity equivalent of the `eks.amazonaws.com/role-arn`
  annotation IRSA uses.
- **Azure AD RBAC**: `admin_group_object_ids` defaults to empty, meaning
  day-to-day kubectl access falls back to `az aks get-credentials` with
  local accounts. If you want proper Azure AD-backed RBAC (closer to how
  enterprise Azure shops run it, and a good thing to mention in
  interviews), get your Azure AD group's object ID and set it in
  `terraform.tfvars`.

## Sanity checks after apply

```bash
kubectl get nodes
kubectl get pods -A
kubectl get pods -A -o wide   # confirm pod IPs fall inside 10.10.0.0/20 (Azure CNI)
kubectl get storageclass      # confirm managed-premium exists
```
