# The secrets operator's permission to read from AWS.
#
# Three things live here and all three are AWS objects: a role, what the role
# may read, and the record that entitles one service account in this cluster to
# assume it. Nothing in this file touches Kubernetes. That is the point — the
# operator's service account is created by the delivery controller from what is
# committed in this repository, carries no annotation, and does not know a role
# exists. The two halves meet in the association below, which names the service
# account by namespace and name rather than by anything it contains.
#
# Phase 1's identity exercise failed the other way round: both halves were made
# by hand, and the half that named the cluster's identity provider stopped
# matching the moment the cluster was rebuilt. There is no identity provider in
# this mechanism, so there is nothing in the trust policy to go out of date.

data "aws_caller_identity" "current" {}

# The trust policy. A fixed service principal, not a cluster-specific identity
# provider, which is why a rebuilt cluster does not invalidate it. Session
# tagging is included because the service attaches the cluster, namespace and
# service account to the session as tags, and refusing it means refusing the
# assume.
data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    sid     = "AllowEksAuthToAssumeRoleForPodIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# Read, and only the reads the operator actually performs: fetch a value, and
# describe a secret in order to notice that its value has moved on. Listing
# secrets is absent deliberately — the operator is told which secrets to fetch
# by what is committed, so it never needs to discover them, and a role that can
# enumerate an account's secrets tells an attacker what is worth going after
# even if it cannot read any of them.
#
# The resource pattern is built from values this configuration already holds
# rather than written out. The trailing wildcard is not optional laxness: every
# secret identifier in this service ends in six random characters assigned at
# creation, so an exact identifier cannot be known before the secret exists.
data "aws_iam_policy_document" "external_secrets_read" {
  statement {
    sid    = "ReadPlatformSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]

    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_name_prefix}/*",
    ]
  }
}

resource "aws_iam_role" "external_secrets" {
  # Named after the cluster, so that two clusters in one account do not share a
  # role and the blast radius of this one stays legible.
  name               = "${var.cluster_name}-external-secrets"
  description        = "Read access to platform secrets for the in-cluster secrets operator, bound to one service account by pod identity."
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
}

resource "aws_iam_policy" "external_secrets_read" {
  name        = "${var.cluster_name}-external-secrets-read"
  description = "Read the platform's own secrets and nothing else."
  policy      = data.aws_iam_policy_document.external_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "external_secrets_read" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets_read.arn
}

# The binding itself, and the reason no account identifier appears anywhere in
# this repository's committed Kubernetes manifests.
#
# Both strings below have to match objects the delivery controller creates from
# what is committed. Nothing enforces that: this record can be created against
# a namespace and a service account that do not exist, and it will sit there
# doing nothing until they do. That is a genuine weakness of putting the
# binding on this side — the mismatch is silent, and it presents in the
# operator's logs as a refusal to assume rather than as a name that does not
# match. The service account name is therefore set explicitly in the operator's
# own configuration rather than left to the chart's naming template, so that
# both sides of the pair are written down as literals and can be read against
# each other.
resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = var.external_secrets_namespace
  service_account = var.external_secrets_service_account
  role_arn        = aws_iam_role.external_secrets.arn
}
