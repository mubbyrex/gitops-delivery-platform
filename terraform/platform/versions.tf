terraform {
  # Pinned to an exact version rather than a range, for the same reason the
  # cluster configuration is: a reader should be able to reproduce this.
  required_version = "1.16.1"

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
