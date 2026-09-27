terraform {
  # Patch releases of Terraform itself are allowed; minor and major ones are
  # not. What gets built is decided by the provider versions below, and those
  # are exact. Terraform's own patch releases do not change the resources a
  # configuration produces, so refusing them buys no reproducibility and
  # costs an edit here every few weeks.
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }
  }
}

# The upstream networking and cluster modules declare providers of their own,
# which appear in .terraform.lock.hcl without being named here. They are
# dependencies of those modules rather than of this configuration, and the
# lock file is what pins them.
