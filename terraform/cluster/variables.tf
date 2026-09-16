variable "region" {
  description = "AWS region to deploy into. Defaulted rather than left open so that the region is fixed by this configuration instead of inherited from whatever the surrounding shell is set to, and so that the running costs quoted for this platform stay true, since prices differ by region and every figure published here was taken from this one."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used to name the network around it, so every resource in the account can be traced back to the cluster it belongs to."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. Needs to be generous: the cluster networking plugin assigns pod addresses out of the node's own subnet, so subnet size is a ceiling on how many pods can run in a zone."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across. Two is the minimum a cluster will accept."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "A cluster requires subnets in at least two availability zones."
  }
}

variable "project" {
  description = "Value of the Project tag applied to every taggable resource. This is the key cost reports are grouped by, so it must stay stable once anything is built on it."
  type        = string
  default     = "kestrel-pay-platform"
}

variable "environment" {
  description = "Value of the Environment tag applied to every taggable resource."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags applied to every taggable resource, merged with the Project and Environment tags. Those two keys are set in the provider configuration rather than here, because their spelling is what cost allocation matches on and it must not vary."
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the cluster control plane. Held one release behind the newest available: current enough to be worth running, settled enough not to be the first to find a regression. Standard support for this version runs to March 2027, comfortably past the life of this platform."
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = "EC2 instance type for the node group. The default is the cheapest type that clears the pod-per-node ceiling the cluster networking plugin imposes, with room to spare for what runs here today. It is expected to need raising once a metrics stack is added, because that is where memory rather than pod count becomes the limit."
  type        = string
  default     = "t3.small"
}

variable "node_count" {
  description = "Number of nodes in the managed node group. Two rather than one so that workloads have somewhere to express anti-affinity and disruption budgets, neither of which means anything on a single node."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 2
    error_message = "Two nodes is the minimum: a single node makes anti-affinity and disruption budgets meaningless."
  }
}

variable "endpoint_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint. Deliberately has no default. The endpoint is public so that this platform can be inspected and run without a bastion, and the only thing standing between that decision and an API server open to the whole internet is this list, so it has to be stated rather than inherited. Narrow it to the operator's own address."
  type        = list(string)

  validation {
    condition     = length(var.endpoint_allowed_cidrs) > 0
    error_message = "At least one CIDR block must be allowed, or the cluster API is unreachable."
  }
}
