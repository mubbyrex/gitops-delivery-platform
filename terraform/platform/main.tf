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
