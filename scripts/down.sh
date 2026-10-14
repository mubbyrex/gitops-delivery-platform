#!/usr/bin/env bash
# Park the platform. Destroys without asking, for the same reason up.sh
# applies without asking.
#
# Order matters: the controller's own objects go first, while it is still
# running to process them, and the cluster underneath goes second.
#
# A thin wrapper on purpose. Teardown duration varies by a factor of two
# between runs, mostly in the node group, and the temptation is to drain nodes
# here to make it predictable. That would be reimplementing what the managed
# node group already does. The variance is recorded rather than papered over.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require terraform aws kubectl
started=$(date +%s)

if [ "$(state_count "$PLATFORM_DIR")" -gt 0 ]; then
  say "Removing the delivery controller"
  terraform -chdir="$PLATFORM_DIR" destroy -auto-approve -input=false \
    -var "cluster_name=$CLUSTER_NAME"
else
  say "Delivery controller: nothing in state, skipping"
fi

if [ "$(state_count "$CLUSTER_DIR")" -gt 0 ]; then
  say "Removing the cluster and network"
  terraform -chdir="$CLUSTER_DIR" destroy -auto-approve -input=false \
    -var "cluster_name=$CLUSTER_NAME" \
    -var "endpoint_allowed_cidrs=[\"$(my_cidr)\"]"
else
  say "Cluster: nothing in state, skipping"
fi

# A context left pointing at a destroyed endpoint makes kubectl hang and then
# time out, which reads as a network or permissions fault. Removing it makes
# the next attempt fail immediately and say what is actually wrong.
say "Removing the kubeconfig entry"
ctx="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CLUSTER_NAME')].context.cluster}" 2>/dev/null || true)"
usr="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CLUSTER_NAME')].context.user}" 2>/dev/null || true)"
kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 && note "context removed" || note "no context to remove"
[ -n "$ctx" ] && kubectl config delete-cluster "$ctx" >/dev/null 2>&1 || true
[ -n "$usr" ] && kubectl config delete-user "$usr" >/dev/null 2>&1 || true

say "Checking for anything Terraform does not own"
if leak_check; then
  note "nothing left behind"
else
  note ""
  note "the resources above were not created by Terraform and will keep billing."
  note "remove them by hand, then run this again."
fi

say "Down after $(( ($(date +%s) - started) / 60 ))m$(( ($(date +%s) - started) % 60 ))s"
