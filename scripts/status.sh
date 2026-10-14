#!/usr/bin/env bash
# What exists, what it costs, and how to reach it. Reads only; changes nothing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

command -v aws >/dev/null 2>&1 || { echo "aws is not installed"; exit 1; }

say "What Terraform believes it is holding"
c=$(state_count "$CLUSTER_DIR"); p=$(state_count "$PLATFORM_DIR")
note "cluster/   $c resources"
note "platform/  $p resources"
# State is a local file. If it is lost while resources still exist, the next
# up.sh builds a second set and the first becomes spend nobody can see.
[ ! -f "$CLUSTER_DIR/terraform.tfstate" ] && note "WARNING: cluster/ has no state file at all"

say "What is actually running"
billable_summary

say "Anything Terraform does not own"
leak_check && note "nothing" || true

if [ "$c" -gt 0 ] && kubectl --context "$CLUSTER_NAME" get nodes >/dev/null 2>&1; then
  say "Cluster"
  kubectl --context "$CLUSTER_NAME" get nodes --no-headers | awk '{printf "  %-34s %s\n",$1,$2}'
  app="$(kubectl --context "$CLUSTER_NAME" -n argocd get application root \
        -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  note "root application: ${app:-not installed}"

  say "Reaching the console"
  note "kubectl port-forward -n argocd svc/argo-cd-argocd-server 8080:443"
  note "then https://localhost:8080 as admin"
  # Regenerated on every build, so it is read out rather than stored anywhere.
  pw="$(kubectl --context "$CLUSTER_NAME" -n argocd get secret argocd-initial-admin-secret \
       -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  note "password: ${pw:-<not available>}"

  say "Cost"
  note "roughly \$0.19/hour while this is up — about \$4.60 a day"
else
  say "Cost"
  note "nothing running, nothing billing"
fi
