provider "aws" {
  region = var.region
}

# The cluster is found by name through the AWS API, not by reading the other
# configuration's state file. That keeps the contract between the two down to
# a single string. Neither side needs a shared state backend, neither depends
# on the other's internal output names, and either can be applied from a
# different machine.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  # Credentials are produced by running the AWS CLI at the moment a provider
  # is configured, not by reading a token during plan. Cluster tokens are
  # short-lived. A token fetched at plan time is baked into the saved plan,
  # and a plan reviewed and applied later fails with an authentication error
  # that looks like a permissions problem and is not one. Running the command
  # at apply time means the token is always fresh, however long the plan sat.
  #
  # The region is passed explicitly. Without it the CLI falls back to the
  # shell's default region, which is not guaranteed to be this one.
  exec_api_version = "client.authentication.k8s.io/v1beta1"
  exec_command     = "aws"
  exec_args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]

  cluster_endpoint = data.aws_eks_cluster.this.endpoint
  cluster_ca       = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca

  exec {
    api_version = local.exec_api_version
    command     = local.exec_command
    args        = local.exec_args
  }
}

# Same credentials, different syntax: this provider takes its cluster
# connection as a nested attribute rather than as blocks.
provider "helm" {
  # Keep chart resolution inside this directory instead of using whatever
  # repository list and cache exist on the machine. Without this the provider
  # reads the operator's own Helm configuration, and a single stale entry there
  # — a repository whose index was never downloaded — is enough to stop a plan
  # from resolving a chart that has nothing to do with it.
  #
  # Both paths are generated and ignored by version control. The point is that
  # what this configuration installs depends only on what is in this
  # repository.
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm/cache"

  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca

    exec = {
      api_version = local.exec_api_version
      command     = local.exec_command
      args        = local.exec_args
    }
  }
}

# The namespace is created here rather than by the chart. The chart can make
# its own, but then the namespace exists only as a side effect of the release
# and disappears with it. Keeping it separate means one object, one owner, and
# a boundary that stays visible in state.
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# The delivery controller itself. This is the last thing installed by
# Terraform rather than from source control, and that ordering is the whole
# point: something outside the cluster has to create the component that
# everything inside the cluster is then managed by.
#
# The cost is that it cannot upgrade itself. A version bump is a change here,
# not a change committed to a repository. For a bootstrap component that is
# the safer side of the trade, because a bad configuration change cannot
# leave the thing that would repair it unable to start.
resource "helm_release" "argocd" {
  name = "argo-cd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  # The namespace above already exists by the time this runs, and letting the
  # release create one as well would give two owners to the same object.
  create_namespace = false

  # Wait for the release to report ready rather than returning as soon as the
  # objects are accepted. Anything applied afterwards depends on the
  # controller actually running, not merely existing.
  #
  # The default allowance is five minutes. These are small burstable nodes
  # pulling several images for the first time, which can take longer than that
  # without anything being wrong.
  wait    = true
  timeout = 900
}

# The handover. One Application, pointing at a path in this repository, with
# automatic sync on. From here the cluster's contents are decided by what is
# committed rather than by what is applied from a workstation.
#
# Self-heal is on from the start deliberately. Without it the committed state
# is only the starting state, and anything changed directly against the cluster
# stays changed. With it, the repository is the authority and drift is
# corrected rather than merely reported.
#
# This is wrapped in a chart rather than declared as a Kubernetes resource
# because of a plan-time ordering constraint. The reasoning is in the chart's
# own template, next to the thing it explains.
resource "helm_release" "root_application" {
  name      = "root-application"
  chart     = "${path.module}/root-application"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name

  # Not an ordering nicety. The type this creates does not exist until the
  # release below has been applied, and nothing in the configuration implies
  # that on its own.
  depends_on = [helm_release.argocd]

  values = [yamlencode({
    name           = "root"
    namespace      = var.argocd_namespace
    repoURL        = var.repo_url
    targetRevision = var.repo_revision
    path           = var.root_path
  })]
}
