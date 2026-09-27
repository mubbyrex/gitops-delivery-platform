variable "cluster_name" {
  description = "Name of the cluster to install onto. This is the only value the two configurations share, and it is deliberately a name rather than an endpoint or a credential: everything else about the cluster is looked up from AWS at plan time, so this configuration can run from any machine that can reach the account."
  type        = string
}

variable "region" {
  description = "AWS region the cluster is in. Must match the region the cluster was created in. Defaulted for the same reason as in the cluster configuration: so the value comes from here and not from whatever the surrounding shell is set to, which on a machine used for more than one account is rarely the right one."
  type        = string
  default     = "us-east-1"
}

variable "argocd_namespace" {
  description = "Namespace the delivery controller is installed into. Created here rather than by the chart, so that it is a distinct object with a single owner instead of a side effect of a release."
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Exact chart version to install. A literal, never a range: this component is what applies everything else to the cluster, so an unannounced change to it is an unannounced change to the whole delivery path. Upgrading is an edit here."
  type        = string
  default     = "10.9.2"
}

variable "repo_url" {
  description = "HTTPS URL of the repository the delivery controller watches. HTTPS rather than SSH, and a public repository, so that the controller needs no credential to read it. The moment this repository becomes private, a credential has to be supplied and managed, which is a different problem than the one being solved here."
  type        = string
  default     = "https://github.com/mubbyrex/gitops-delivery-platform.git"
}

variable "repo_revision" {
  description = "Branch the delivery controller tracks. Named explicitly rather than following whatever the default branch happens to be, so that repointing it is a visible change."
  type        = string
  default     = "main"
}

variable "root_path" {
  description = "Path inside the repository that the controller watches. Everything the cluster runs arrives through here."
  type        = string
  default     = "argocd/root"
}
