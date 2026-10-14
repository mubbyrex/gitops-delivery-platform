# Shared settings and helpers for the lifecycle scripts.
# Sourced by up.sh, down.sh and status.sh; not meant to be run on its own.

CLUSTER_NAME="${CLUSTER_NAME:-kestrel-pay-dev}"
REGION="${REGION:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="$REPO_ROOT/terraform/cluster"
PLATFORM_DIR="$REPO_ROOT/terraform/platform"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c is not installed"
  done
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no working AWS credentials for this shell"
}

# The allowlist for the API endpoint has no default on purpose, so it has to
# come from somewhere each time. Here, from wherever this machine currently
# appears on the internet — which changes, and is the whole reason the setting
# exists rather than being baked in.
my_cidr() {
  local ip
  ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')" \
    || die "could not work out this machine's public address"
  [ -n "$ip" ] || die "empty response when looking up this machine's address"
  printf '%s/32' "$ip"
}

# How many resources a module believes it is holding.
state_count() {
  terraform -chdir="$1" state list 2>/dev/null | wc -l | tr -d ' '
}

# Resources an in-cluster controller can create that Terraform never learns
# about: load balancers asked for by an ingress, volumes asked for by a claim,
# and the security groups that come with them. A destroy does not remove these
# because nothing in the state file points at them.
#
# Deliberately per-service rather than one query by tag. The tag inventory goes
# on reporting deleted resources for a while after a teardown, so it reads as a
# leak when there is none. These calls tell the truth.
leak_check() {
  local leaked=0 out

  out="$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null | tr -d '[:space:]')"
  [ -n "$out" ] && { note "load balancers still present: $out"; leaked=1; }

  out="$(aws elb describe-load-balancers --region "$REGION" \
        --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null | tr -d '[:space:]')"
  [ -n "$out" ] && { note "classic load balancers still present: $out"; leaked=1; }

  out="$(aws ec2 describe-volumes --region "$REGION" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr -d '[:space:]')"
  [ -n "$out" ] && { note "EBS volumes still present: $out"; leaked=1; }

  out="$(aws ec2 describe-addresses --region "$REGION" \
        --query 'Addresses[].PublicIp' --output text 2>/dev/null | tr -d '[:space:]')"
  [ -n "$out" ] && { note "elastic IPs still allocated: $out"; leaked=1; }

  out="$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr -d '[:space:]')"
  [ -n "$out" ] && { note "cluster security groups still present: $out"; leaked=1; }

  return $leaked
}

# Everything that bills by the hour, whether or not Terraform owns it.
billable_summary() {
  printf '  %-22s %s\n' "EKS clusters:" \
    "$(aws eks list-clusters --region "$REGION" --query 'clusters' --output text 2>/dev/null | grep . || echo none)"
  printf '  %-22s %s\n' "EC2 instances:" \
    "$(aws ec2 describe-instances --region "$REGION" \
       --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
       --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | grep . || echo none)"
  printf '  %-22s %s\n' "NAT gateways:" \
    "$(aws ec2 describe-nat-gateways --region "$REGION" \
       --filter Name=state,Values=pending,available \
       --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | grep . || echo none)"
}
