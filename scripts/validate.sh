#!/usr/bin/env bash
# Everything the requirements call for before a task is complete, in one
# place, so that passing stops depending on remembering which flags to use.
#
# This exists because the alternative was discovered not to work. The schema
# check reported "13 resources found, 0 invalid" over a directory of delivery
# controller applications while knowing nothing about that resource type: it
# had skipped all thirteen and reported success. A check that cannot fail is
# worse than no check, because it is counted as evidence.
#
# So the schema catalogue below is not optional detail. Without it, the only
# files checked are the ones the cluster's own types already describe, which
# is exactly the half least likely to be wrong.
#
# Needs network: the catalogue is fetched, not vendored. Reads nothing from a
# running cluster, so it works with everything torn down.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

failed=0
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; failed=1; }
pass() { printf '  ok    %s\n' "$*"; }

# Schemas for the types a plain Kubernetes install does not ship. Without the
# second location, anything defined by a controller is silently skipped.
CATALOGUE='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
schema_check() {
  local label="$1"; shift
  local out
  if out=$(kubeconform -strict -summary \
             -schema-location default \
             -schema-location "$CATALOGUE" "$@" 2>&1); then
    case "$out" in
      # Nothing found is not success. An empty file passes every check that
      # iterates over what is in it, which is how a first draft of this
      # script reported six renderings valid while rendering nothing at all.
      *"0 resource found"*) fail "$label — nothing was rendered, so nothing was checked" ;;
      *"Skipped: 0"*)       pass "$label — ${out##*Summary: }" ;;
      *)                    fail "$label — something was skipped, so it was not checked: ${out##*Summary: }" ;;
    esac
  else
    fail "$label"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

# Deliberately not common.sh's require(), which also insists on working cloud
# credentials. Nothing below talks to a cloud or a cluster, and a validator
# that cannot run without credentials is one that gets skipped.
for c in terraform helm kubeconform python3; do
  command -v "$c" >/dev/null 2>&1 || die "$c is not installed"
done

say "Terraform"
for d in "$CLUSTER_DIR" "$PLATFORM_DIR"; do
  n=$(basename "$d")
  terraform -chdir="$d" fmt -check >/dev/null 2>&1 \
    && pass "$n formatted" || fail "$n is not formatted — run terraform fmt"
  terraform -chdir="$d" validate -no-color >/dev/null 2>&1 \
    && pass "$n valid" || { fail "$n invalid"; terraform -chdir="$d" validate -no-color 2>&1 | sed 's/^/        /'; }
done

say "Charts"
for c in "$REPO_ROOT"/charts/*/; do
  helm lint "$c" >/dev/null 2>&1 \
    && pass "$(basename "$c") lints" \
    || { fail "$(basename "$c") does not lint"; helm lint "$c" 2>&1 | sed 's/^/        /'; }
done

say "Rendered manifests"
# A chart is rendered the way the cluster renders it: once per environment
# that supplies values for it. Rendering with chart defaults instead would
# check a combination nothing deploys.
rendered=0
for vals in "$REPO_ROOT"/environments/*/*.yaml; do
  env=$(basename "$(dirname "$vals")")
  name=$(basename "$vals" .yaml)
  chart="$REPO_ROOT/charts/$name"
  [ -d "$chart" ] || { fail "$env/$name has values but no chart"; continue; }
  # The suffix is load-bearing. The checker selects files by extension, so a
  # temporary file without one is read as nothing at all and reports a clean
  # summary over zero resources.
  out="$(mktemp --suffix=.yaml)"
  if helm template "$name" "$chart" -f "$vals" --namespace "$env" 2>/dev/null | tee "$out" >/dev/null \
     && [ -s "$out" ]; then
    schema_check "$name in $env" "$out"
    rendered=$((rendered + 1))
  else
    fail "$name in $env does not render"
    helm template "$name" "$chart" -f "$vals" --namespace "$env" 2>&1 | tail -5 | sed 's/^/        /'
  fi
  rm -f "$out"
done
# Charts whose values the delivery controller carries inline rather than in
# an environment file. Rendering those with chart defaults does not work and
# should not: one of them refuses to render without a region, on purpose, so
# that a misconfigured store fails loudly instead of reading from somewhere
# nobody chose. The values are therefore taken from the application that
# deploys the chart, which is also the only rendering that matches the
# cluster.
inline_values() {
  python3 - "$REPO_ROOT" "$1" <<'PYEOF'
import sys, glob, os, yaml
root, chart = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob(os.path.join(root, 'argocd', 'root', '*.yaml'))):
    try:
        app = yaml.safe_load(open(f))
    except Exception:
        continue
    if not isinstance(app, dict) or app.get('kind') != 'Application':
        continue
    spec = app.get('spec', {})
    for src in ([spec['source']] if 'source' in spec else spec.get('sources', [])):
        if src.get('path') == f'charts/{chart}':
            sys.stdout.write(src.get('helm', {}).get('values', '') or '')
            sys.exit(0)
sys.exit(1)
PYEOF
}

for c in "$REPO_ROOT"/charts/*/; do
  name=$(basename "$c")
  ls "$REPO_ROOT"/environments/*/"$name".yaml >/dev/null 2>&1 && continue
  vals="$(mktemp --suffix=.yaml)"
  inline_values "$name" 2>/dev/null | tee "$vals" >/dev/null
  # An application may legitimately supply nothing, where the chart's own
  # defaults are what gets deployed. That is a different case from a chart
  # whose values went missing, and only the rendering can tell them apart.
  if [ -s "$vals" ]; then
    set -- -f "$vals"; how="values from its application"
  else
    set --;            how="chart defaults, as its application supplies none"
  fi
  out="$(mktemp --suffix=.yaml)"
  if helm template "$name" "$c" "$@" --namespace default 2>/dev/null | tee "$out" >/dev/null \
     && [ -s "$out" ]; then
    schema_check "$name ($how)" "$out"
    rendered=$((rendered + 1))
  else
    fail "$name does not render with $how"
    helm template "$name" "$c" "$@" --namespace default 2>&1 | tail -3 | sed 's/^/        /'
  fi
  rm -f "$out" "$vals"
done
note "$rendered renderings checked"

say "Delivery controller applications"
schema_check "argocd/root" "$REPO_ROOT"/argocd/root/*.yaml

say "Workflows"
for w in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
  [ -e "$w" ] || continue
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$w" >/dev/null 2>&1 \
    && pass "$(basename "$w") parses" || fail "$(basename "$w") does not parse"
done

say "Secrets and identifiers"
# Scanned over what could reach the public history, not over the working
# directory. Those are different sets, and the difference matters: generated
# state holds the account identifier by nature and always will, so a scan of
# the directory reports a violation that cannot be fixed and gets ignored,
# which is how a real one would get through. What is checked instead is that
# such files cannot be committed at all.
say_files() { git -C "$REPO_ROOT" ls-files -co --exclude-standard; }
leaked=$(say_files | while read -r f; do
           grep -EHn '\b[0-9]{12}\b|AKIA[0-9A-Z]{16}|[A-Za-z0-9]{32}\.gr[0-9]\.[a-z0-9-]+\.eks\.amazonaws\.com' \
             "$REPO_ROOT/$f" 2>/dev/null
         done)
if [ -z "$leaked" ]; then
  pass "nothing committable holds an account identifier, key prefix or endpoint"
else
  fail "a committable file holds an identifier"
  printf '%s\n' "$leaked" | sed 's/^/        /'
fi

# Images are the one thing this scan cannot do anything about, and saying so is
# the point. An identifier shown in a screenshot is pixels, not bytes, so a
# pattern search over the file reads clean whatever the picture contains. The
# count is printed so that a passing run never implies these were checked.
binaries=$(say_files | grep -cEi '\.(png|jpe?g|gif|webp|pdf|drawio)$' || true)
if [ "${binaries:-0}" -gt 0 ]; then
  printf '  \033[33mnote\033[0m  %s image or binary file(s) were NOT checked — a screenshot showing an
' "$binaries"
  printf '        account number or a cluster address reads clean to this scan. Look at them.\n'
fi

# The gitignored working directory is authored by hand and is one rename away
# from being published, so it is scanned too, by the same rule.
if [ -d "$REPO_ROOT/specs" ]; then
  leaked=$(grep -rEn '\b[0-9]{12}\b|AKIA[0-9A-Z]{16}' "$REPO_ROOT/specs" 2>/dev/null || true)
  [ -z "$leaked" ] && pass "the working directory is clean too" \
    || { fail "the working directory holds an identifier"; printf '%s\n' "$leaked" | sed 's/^/        /'; }
fi

# The rule the scan above depends on. If these stop being ignored, the scan
# starts reading them and the check above becomes the noise it was designed
# not to be.
tracked=$(git -C "$REPO_ROOT" ls-files | grep -E '\.tfstate|\.tfvars$|kubeconfig|\.pem$' || true)
[ -z "$tracked" ] && pass "no state, variable or credential file is tracked" \
  || { fail "a file that must never be committed is tracked"; printf '%s\n' "$tracked" | sed 's/^/        /'; }

say "Repository map"
# Both directions, because a map can be wrong by describing what is absent or
# by omitting what is present -- and the private map this replaced managed the
# first, documenting seven directories that were never built.
MAP="$REPO_ROOT/docs/structure.md"
if [ ! -f "$MAP" ]; then
  fail "docs/structure.md is missing"
else
  missing=""
  # every directory the map names inside its tree block must exist
  while read -r d; do
    [ -z "$d" ] && continue
    [ -d "$REPO_ROOT/$d" ] || missing="$missing $d"
  done <<EOF
$(grep -oE '^[a-z.][a-zA-Z0-9_.-]*/[a-zA-Z0-9_./-]*' "$MAP" | sed 's#/$##' | sort -u)
EOF
  absent=""
  # every tracked top-level directory must be named in the map
  for d in $(git -C "$REPO_ROOT" ls-files | awk -F/ 'NF>1{print $1}' | sort -u); do
    grep -q "$d/" "$MAP" || absent="$absent $d"
  done
  if [ -z "$missing" ] && [ -z "$absent" ]; then
    pass "docs/structure.md matches the tree, in both directions"
  else
    [ -n "$missing" ] && fail "the map names directories that do not exist:$missing"
    [ -n "$absent" ]  && fail "the tree has directories the map never mentions:$absent"
  fi
fi

say "Decisions log"
if "$REPO_ROOT/scripts/check-decisions.sh" >/dev/null 2>&1; then
  pass "every entry states a cost, and the log is not behind"
else
  fail "see scripts/check-decisions.sh"
fi

echo
if [ "$failed" -eq 0 ]; then
  printf '\033[32mPASS\033[0m — everything the requirements ask for before a task is done.\n'
else
  printf '\033[31mFAIL\033[0m — fix the above before marking anything complete.\n'
fi
exit "$failed"
