provider "aws" {
  region = var.region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region",       var.region
      ]
    }
  }
}

# Use exec instead of static token to fetch fresh AWS credentials at apply time, avoiding stale token auth errors
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region",       var.region
    ]
  }
}

data "aws_availability_zones" "available" {
    state = "available"
}

module "vpc" {
    source = "terraform-aws-modules/vpc/aws"
    version = "~> 5.0"

    name = "${var.cluster_name}-vpc"
    cidr = "10.0.0.0/16"

    # asks AWS which AZs are available in us-east-1 (there are 6, we take the first 2)
    azs = slice(data.aws_availability_zones.available.names, 0, 2)
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
    public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

    enable_nat_gateway   = true
    single_nat_gateway   = true
    enable_dns_hostnames = true

    public_subnet_tags = {
        "kubernetes.io/role/elb" = 1
    }

    private_subnet_tags = {
        "kubernetes.io/role/internal-elb" = 1
    }

    tags = {
        Project   = "dota2metalab"
        ManagedBy = "terraform"
    }
}

module "eks" {
    source = "terraform-aws-modules/eks/aws"
    version = "~> 20.0"

    cluster_name    = var.cluster_name
    cluster_version = var.cluster_version

    vpc_id     = module.vpc.vpc_id
    subnet_ids = module.vpc.private_subnets

    cluster_endpoint_public_access = true

    enable_cluster_creator_admin_permissions = true

    eks_managed_node_groups = {
        main = {
            instance_types = [var.node_instance_type]
            min_size       = 1
            max_size       = 4
            desired_size   = var.node_count
            capacity_type  = "ON_DEMAND"
        }

        tags = {
            "k8s.io/cluster-autoscaler/enabled"                    = "true"
            "k8s.io/cluster-autoscaler/${var.cluster_name}"        = "owned"
        }
    }

    cluster_addons = {
        aws-ebs-csi-driver = {
            most_recent = true
            service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
        }
    }

    tags = {
        Project   = "dota2metalab"
        ManagedBy = "terraform"
    }
}

module "ebs_csi_irsa" {
    source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
    version = "~> 5.0"

    role_name = "ebs-csi-${var.cluster_name}"
    attach_ebs_csi_policy = true

    oidc_providers = {
        main = {
            provider_arn = module.eks.oidc_provider_arn
            namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
        }
    }
}

# installs the argocd
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

  depends_on = [module.eks]
}

# installs the nginx
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
  
  depends_on = [module.eks]
}

resource "kubectl_manifest" "argocd_root_app" {
    yaml_body = file(abspath("${path.module}/../../argocd-apps/root-app.yaml"))
    depends_on = [ helm_release.argocd ]
}

resource "kubectl_manifest" "argocd_ingress" {
  yaml_body = file(abspath("${path.module}/../../deploy/argocd/argocd-ingress.yaml"))

  depends_on = [helm_release.argocd]
}

resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
  }

  depends_on = [ module.eks ]
}

# Cloudflare load balancer
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "kubernetes_service_v1" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}

resource "cloudflare_record" "root" {
  zone_id           =   var.cloudflare_zone_id
  name              =   "@"
  content           =   data.kubernetes_service_v1.ingress_nginx.status.0.load_balancer.0.ingress.0.hostname
  type              =   "CNAME"
  proxied           =   true
  allow_overwrite   =   true
}

resource "cloudflare_record" "staging" {
  zone_id           =   var.cloudflare_zone_id
  name              =   "staging"
  content           =   data.kubernetes_service_v1.ingress_nginx.status.0.load_balancer.0.ingress.0.hostname
  type              =   "CNAME"
  proxied           =   true
  allow_overwrite   =   true
}

resource "cloudflare_record" "argocd" {
  zone_id           =   var.cloudflare_zone_id
  name              =   "argocd"
  content           =   data.kubernetes_service_v1.ingress_nginx.status.0.load_balancer.0.ingress.0.hostname
  type              =   "CNAME"
  proxied           =   true
  allow_overwrite   =   true
}

# =============================================================
# S3 Model Storage
# Replaces EBS PVC for ML model artifacts.
# EBS caused WaitForFirstConsumer deadlock on EKS — S3 is the
# production-grade solution for sharing models across pods/envs.
# =============================================================

resource "aws_s3_bucket" "models" {
  bucket = "dota2metalab-models-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project   = "dota2metalab"
    ManagedBy = "terraform"
  }
}

# Keep full model history — enables rollback to previous model versions
resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt all model artifacts at rest using AES-256
resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — models are internal assets only
resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Used to make S3 bucket name globally unique using AWS account ID
data "aws_caller_identity" "current" {}

# IAM policy granting pods least-privilege access to model bucket only
# Attached to service account via IRSA — no hardcoded credentials
resource "aws_iam_policy" "s3_models" {
  name        = "dota2metalab-s3-models"
  description = "Allow pods to read/write ML models to S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",    # API reads model files
          "s3:PutObject",    # Trainer writes model files
          "s3:DeleteObject", # Cleanup old models
          "s3:ListBucket"    # List available model versions
        ]
        Resource = [
          aws_s3_bucket.models.arn,
          "${aws_s3_bucket.models.arn}/*"
        ]
      }
    ]
  })
}

# IRSA role for pods to access S3 model bucket
# Allows trainer and API pods to read/write models without hardcoded credentials
# Create an IAM role that can be assumed by:
#  - dota2metalab-api service account in any namespace
#  - dota2metalab-trainer service account in any namespace
# And attach the S3 models policy to it
module "s3_models_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name = "dota2metalab-s3-models"

  role_policy_arns = {
    s3_models = aws_iam_policy.s3_models.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "dota2metalab-dev:dota2metalab-api",
        "dota2metalab-staging:dota2metalab-api",
        "dota2metalab-prod:dota2metalab-api",
        "dota2metalab-dev:dota2metalab-trainer",
        "dota2metalab-staging:dota2metalab-trainer",
        "dota2metalab-prod:dota2metalab-trainer"
      ]
    }
  }
}

# Metrics server
resource "helm_release" "metrics_server" {
  name = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart = "metrics-server"
  namespace = "kube-system"

  set {
    name = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [module.eks]
}

# CLuster Autoscaler
# IAM policy for Cluster Autoscaler
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "dota2metalab-cluster-autoscaler"
  description = "Policy for Cluster Autoscaler to manage EC2 nodes"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstanceTypes"
        ]
        Resource = "*"
      }
    ]
  })
}

# IRSA role for Cluster Autoscaler
module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name = "dota2metalab-cluster-autoscaler"

  role_policy_arns = {
    cluster_autoscaler = aws_iam_policy.cluster_autoscaler.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

# Install Cluster Autoscaler via Helm
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = "us-east-1"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cluster_autoscaler_irsa.iam_role_arn
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  depends_on = [module.eks]
}

resource "null_resource" "argocd_sync" {
  depends_on = [helm_release.cluster_autoscaler]

  provisioner "local-exec" {
    command = <<EOT
      argocd login ${var.argocd_host} \
        --username admin \
        --password ${var.argocd_password} \
        --insecure --grpc-web

      argocd app sync dota2metalab-prod --force
      argocd app wait dota2metalab-prod --health --timeout 600
    EOT
  }
}