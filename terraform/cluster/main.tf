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
    tags = local.common_tags
  }
}

locals {
  # Defined once and used twice, because one mechanism does not cover
  # everything. Default tags reach every resource this configuration creates
  # directly. They do not reach instances launched later from a launch
  # template, because the tags a template stamps on what it launches are data
  # inside that template rather than tags on the template itself.
  #
  # So the same map is also handed to the cluster module, which puts it where
  # the launch template can apply it. Missing that leaves the nodes - the
  # second largest line on the bill - absent from any report grouped by
  # project.
  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
    },
    var.tags,
  )
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

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Reaches the launch template's tag specification, and from there the
  # instances, volumes and network interfaces it creates. Provider-level
  # defaults cannot do this on their own.
  tags = local.common_tags

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # The API server is reachable from the internet, narrowed to an explicit
  # allowlist. A private-only endpoint is the right answer for a payments
  # platform carrying real traffic; it also needs a bastion or a VPN to
  # operate, and this platform exists to be inspected. The allowlist is the
  # seam where that trade would be reversed.
  #
  # The module defaults the public endpoint to off and this list to the whole
  # internet, so both are set here rather than left alone. Private access
  # stays on as well, which keeps traffic from inside the network off the
  # public path.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_allowed_cidrs
  endpoint_private_access      = true

  # Creates the OIDC provider that lets a pod assume an AWS role through its
  # service account. On by default in this module version, set explicitly
  # because everything that later reaches AWS from inside the cluster hangs
  # off it, and a silent change of default would be expensive to diagnose.
  enable_irsa = true

  # Grants the identity that runs Terraform administrative access to the
  # cluster. This defaults to off: without it the cluster comes up healthy
  # and nobody can talk to it, which looks like a credentials problem and is
  # not one.
  enable_cluster_creator_admin_permissions = true

  # The cluster's own bootstrapping is off, so nothing is installed unless it
  # is asked for here. Versions are literals with tracking off, which makes an
  # upgrade an edit rather than a side effect of some later apply.
  #
  # The network plugin must exist before any node boots -- before_compute is
  # what asks for that -- and DNS has to come after, since it runs as ordinary
  # pods. Getting the order wrong produces no error at all; the consequence is
  # in docs/architecture.md.
  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = false
      addon_version  = "v1.23.1-eksbuild.1"
    }
    kube-proxy = {
      before_compute = true
      most_recent    = false
      addon_version  = "v1.35.3-eksbuild.29"
    }
    coredns = {
      most_recent   = false
      addon_version = "v1.14.3-eksbuild.22"
    }

    # Lets a pod assume an AWS role without the role being named anywhere
    # inside the cluster. The binding is a record held in AWS that names this
    # cluster, a namespace, and a service account; this agent is what the pod
    # talks to in order to collect the credentials that record entitles it to.
    #
    # Without it the binding exists in AWS and simply has no effect, which
    # presents as a permissions error in the pod rather than as anything
    # pointing at a missing component.
    #
    # Pinned to the version the provider itself defaults to for this
    # Kubernetes release, on the same reasoning as the three above: a newer
    # build exists and being first to run it buys nothing here.
    eks-pod-identity-agent = {
      most_recent   = false
      addon_version = "v1.3.10-eksbuild.3"
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      subnet_ids     = module.vpc.private_subnets

      # Nothing scales this group. The ceiling sits one above the desired
      # count so an update can bring a replacement up before taking the old
      # node away.
      #
      # Growing a cluster that is already running is NOT an edit here -- the
      # module ignores later changes to the desired size, so the apply is
      # rejected however reasonable the plan looked. docs/runbook.md has the
      # two-step. Building from nothing is unaffected.
      min_size     = var.node_count
      desired_size = var.node_count
      max_size     = var.node_count + 1
    }
  }
}
