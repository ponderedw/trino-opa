terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  # Replace with your preferred backend.
  # backend "s3" {
  #   bucket  = "my-terraform-state"
  #   key     = "trino/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.aws_region
}

# ── Kubernetes provider ───────────────────────────────────────────────────────
#
# Option A (shown): kubeconfig file — works with any cluster.
# Option B: AWS EKS token — uncomment the exec block below instead.

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kubeconfig_context
  }
}

provider "kubectl" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

# ── External Secrets Operator ─────────────────────────────────────────────────
# ESO is a cluster-wide operator. Install it once; it handles all ExternalSecret
# resources across namespaces.

resource "helm_release" "external_secrets_operator" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.9.20"
  wait             = true
}

# Option B — AWS EKS:
#
# data "aws_eks_cluster" "main" {
#   name = var.eks_cluster_name
# }
#
# provider "kubernetes" {
#   host                   = data.aws_eks_cluster.main.endpoint
#   cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", var.aws_region]
#   }
# }
#
# provider "helm" {
#   kubernetes {
#     host                   = data.aws_eks_cluster.main.endpoint
#     cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
#     exec {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       command     = "aws"
#       args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", var.aws_region]
#     }
#   }
# }

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "trino" {
  metadata {
    name = var.namespace
  }
}

locals {
  trino_namespace = kubernetes_namespace_v1.trino.metadata[0].name
}
