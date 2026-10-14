#!/usr/bin/env bash
# Bring the platform up and hand the cluster over to the delivery controller.
#
# Applies without asking. That is the point of it — a person at a keyboard who
# ran this meant to spend money. Expect fifteen minutes or so, most of it the
# control plane.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require terraform aws kubectl curl
started=$(date +%s)

say "Checking for anything already running"
billable_summary
note "state: cluster/ holds $(state_count "$CLUSTER_DIR"), platform/ holds $(state_count "$PLATFORM_DIR")"

cidr="$(my_cidr)"
say "Building the network and cluster"
note "API endpoint will be reachable from $cidr only"
terraform -chdir="$CLUSTER_DIR" init -input=false >/dev/null
terraform -chdir="$CLUSTER_DIR" apply -auto-approve -input=false \
  -var "cluster_name=$CLUSTER_NAME" \
  -var "endpoint_allowed_cidrs=[\"$cidr\"]"

# The endpoint and its certificate authority are new every time, so the
# kubeconfig entry is rewritten rather than assumed. Naming the context after
# the cluster means this overwrites itself instead of accumulating.
say "Pointing kubectl at it"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null
kubectl --context "$CLUSTER_NAME" wait --for=condition=Ready nodes --all --timeout=300s >/dev/null
note "$(kubectl --context "$CLUSTER_NAME" get nodes --no-headers | grep -c ' Ready ') nodes ready"

say "Installing the delivery controller"
terraform -chdir="$PLATFORM_DIR" init -input=false >/dev/null
terraform -chdir="$PLATFORM_DIR" apply -auto-approve -input=false \
  -var "cluster_name=$CLUSTER_NAME"

say "Waiting for it to settle"
kubectl --context "$CLUSTER_NAME" -n argocd wait --for=condition=available \
  deployment --all --timeout=300s >/dev/null
for _ in $(seq 1 40); do
  s="$(kubectl --context "$CLUSTER_NAME" -n argocd get application root \
       -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [ "$s" = "Synced/Healthy" ] && break
  sleep 5
done
note "root application: ${s:-unknown}"

say "Up after $(( ($(date +%s) - started) / 60 ))m$(( ($(date +%s) - started) % 60 ))s"
note "costing roughly \$0.19/hour from now until down.sh"
note "run scripts/status.sh for the console password and how to reach it"
