provider "aws" {
  region = var.region

  # Applied to every taggable resource this configuration creates, rather than
  # repeated on each one. The two keys are literals: AWS treats Project and
  # project as different cost allocation tags, so the spelling cannot be left
  # to whoever calls this. Callers can add tags but cannot change these.
  #
  # This reaches everything Terraform creates and nothing else. Resources that
  # controllers inside the cluster create later - load balancers, volumes -
  # are invisible to it and have to carry the tag through their own
  # configuration.
  default_tags {
    tags = merge(
      {
        Project     = var.project
        Environment = var.environment
      },
      var.tags,
    )
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  # Excludes Local Zones, Wavelength zones, and zones in opt-in regions that
  # have not been enabled. A cluster cannot place subnets in any of them, and
  # without this filter they can appear in the list and be picked.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Private subnets take large blocks from the bottom of the range and public
  # subnets take small ones from the top, so the two sets cannot collide at
  # any realistic zone count.
  #
  # The asymmetry is deliberate. Pod addresses come out of the private subnet,
  # so its size limits how much can run in that zone. The public subnets hold
  # only the NAT gateway and whatever load balancers appear later, which is a
  # handful of addresses.
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 255 - i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.2"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Nodes run in the private subnets and reach the internet through NAT.
  # One gateway for the whole network rather than one per zone. That is a
  # cost decision with an availability consequence: if the zone holding the
  # gateway fails, every zone loses outbound internet, not just that one.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  # Nodes cannot register with the cluster unless the network resolves DNS
  # and hands out hostnames.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Where load balancers are allowed to go. A controller asked for an
  # internet-facing address looks for the first tag, and an internal one
  # looks for the second. Nothing creates a load balancer yet. A missing tag
  # here does not fail now - it surfaces much later as an ingress that never
  # receives an address, which is a slow thing to trace back to here.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
