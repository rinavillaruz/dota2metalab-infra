provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
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
            max_size       = 3
            desired_size   = var.node_count
            capacity_type  = "ON_DEMAND"
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
