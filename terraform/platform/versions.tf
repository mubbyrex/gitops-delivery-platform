terraform {
  # Patch releases allowed, minor and major not, for the same reason as in the
  # cluster configuration: the provider versions decide what gets built and
  # those stay exact.
  required_version = "~> 1.16"

  required_providers {
    # Locates the existing cluster and supplies the token that the kubernetes
    # and helm providers authenticate with.
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }

    # Creates the namespace Argo CD is installed into.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }

    # Installs Argo CD itself, and the Application that hands the cluster over
    # to it.
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
  }
}
