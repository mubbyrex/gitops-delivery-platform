# These five values are the whole interface this configuration exposes. Each
# one exists because something built later needs it, and nothing else is
# exported so that nothing downstream can grow a dependency on an internal
# detail by accident.

output "cluster_name" {
  description = "Name of the cluster. The single value the platform configuration needs in order to find everything else about the cluster through the AWS API, which is what keeps the two configurations decoupled."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server. Exported for tooling that wants to address the cluster directly. It changes every time the cluster is rebuilt, so nothing should store it."
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's OpenID Connect identity provider. Every IAM role that a pod assumes through its service account trusts this provider, so it is the root of all workload identity on the platform."
  value       = module.eks.oidc_provider_arn

  # The upstream module returns null here rather than failing when the
  # provider was not created. A null would be handed silently to everything
  # that depends on it and surface later as an authentication failure with no
  # obvious cause. Failing here instead names the actual problem.
  precondition {
    condition     = module.eks.oidc_provider_arn != null
    error_message = "The cluster has no OIDC identity provider. Workload identity depends on it; check that enable_irsa is true."
  }
}

output "vpc_id" {
  description = "ID of the VPC the cluster runs in. Needed by anything that has to be placed in the same network later, such as a database."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per availability zone. Nodes run here, and anything that must be reachable from them but not from the internet belongs here too."
  value       = module.vpc.private_subnets
}
