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
