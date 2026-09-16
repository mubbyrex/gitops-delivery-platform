terraform {
  # Pinned to an exact version rather than a range. This platform is meant to
  # be reproducible by anyone who clones it, and a range means two people can
  # run the same commit and get different plans.
  required_version = "1.16.1"

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
