variable "cluster_name" {
  description = "Name of the cluster to install onto. This is the only value the two configurations share, and it is deliberately a name rather than an endpoint or a credential: everything else about the cluster is looked up from AWS at plan time, so this configuration can run from any machine that can reach the account."
  type        = string
}

variable "region" {
  description = "AWS region the cluster is in. Must match the region the cluster was created in. Defaulted for the same reason as in the cluster configuration: so the value comes from here and not from whatever the surrounding shell is set to, which on a machine used for more than one account is rarely the right one."
  type        = string
  default     = "us-east-1"
}
