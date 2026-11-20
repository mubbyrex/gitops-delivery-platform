# Kestrel Pay — GitOps delivery platform

A reference platform that demonstrates one thing: **two workloads whose release
requirements genuinely conflict, delivered differently on purpose, with the
reasoning written down beside the configuration.**

The scenario is invented and [`scenario.md`](scenario.md) says so plainly.
Kestrel Pay does not exist, no real money moves, and the two services are stubs
with a health endpoint, a metrics endpoint and a switch that makes them fail.

---

## The problem it exists to answer

Gradual release rests on three assumptions that are so reliably true of
stateless web services they usually go unstated: that two versions can coexist,
that exposure can be metered, and that you find out you were wrong while the
exposure is still small.

**`payments-api`** satisfies all three. It is a stateless HTTP service, so a
request handled by the old version and one handled by the new have nothing to
do with each other, ten percent of traffic is ten percent of the consequence,
and the error rate moves within seconds.

**`settlement-worker`** satisfies none of them. It is a scheduled batch job
that pays merchants. Two versions running at once is not a mitigation, it is
the failure — both read the same unsettled payments, both decide a payout is
owed, and the merchant is paid twice. Ten percent of a settlement run is not a
safe experiment. And the damage is invisible until a reconciliation report
hours later.

**So the same release mechanism cannot be correct for both.** The API is
released in weighted steps with an automated gate. The worker is released by
replacement and must never run twice at once. The asymmetry is the point, and a
platform that applies one strategy uniformly has misread at least one of them.

---

## What is here

Everything below is built and running, not planned.

| | |
|---|---|
| **Provisioning** | a VPC across two availability zones, an EKS cluster, three nodes in private subnets, workload identity |
| **Delivery** | Argo CD, installed by Terraform and pointed at [`argocd/root/`](argocd/root/) — after that, what runs is decided by what is committed here |
| **Ingress** | Traefik, driven through the Gateway API rather than vendor annotations |
| **Secrets** | External Secrets, reading AWS Secrets Manager through EKS Pod Identity |
| **Measurement** | Prometheus and Grafana, with committed dashboards — one per service, plus one that shows a release while it happens |
| **Logs** | Loki and Alloy — so that *why* a release failed can be answered, not only *whether* |
| **Progressive delivery** | Argo Rollouts — the API releases 10% → 30% → 60% → 100%, three minutes and a gate at each step |
| **Pipeline** | GitHub Actions builds, scans, publishes and commits an image digest. It holds no cluster credential and no cloud credential |

### The release gate, which is the actual deliverable

Three measurements every thirty seconds; three failures abandon the release.

1. **Is the candidate serving at all?** ≥ 0.1 requests/second
2. **What share of its real requests failed?** ≤ 1%
3. **How long did they take?** 95th percentile ≤ 10 ms

The first one is there because of something found by reading the service
closely: a version that cannot stay up serves almost nothing and therefore
*fails* almost nothing. **A gate built on error rate alone would promote a dead
version on a perfect record.** That is not theoretical — it is demonstrated,
and the numbers are in [`docs/decisions.md`](docs/decisions.md).

---

## Reading it

Start here, in this order:

- [`scenario.md`](scenario.md) — the invented scenario and why the two
  workloads conflict
- [`docs/architecture.md`](docs/architecture.md) — the system as built, the
  ownership boundaries, what it costs, and **what this platform does not do**
- [`docs/decisions.md`](docs/decisions.md) — every choice with a real
  alternative, what was rejected, and what the choice costs. Each entry carries
  an accepted cost, because a decision that appears to cost nothing was not one
- [`docs/runbook.md`](docs/runbook.md) — what to do when something is wrong
- [`docs/structure.md`](docs/structure.md) — where everything is, and what
  each directory is for

### Where things live

```
terraform/cluster/     network, EKS, nodes, identity      — applied first
terraform/platform/    Argo CD and the root Application   — applied second
argocd/root/           one file per component Argo CD manages
charts/                one chart per service, identical across environments
environments/<env>/    the only place environments differ
services/              the two Go stubs
scripts/               up, down, status, validate
local/                 a kind cluster for work that does not need AWS
```

Promotion from dev to staging is a person editing the image digest in
`environments/staging/<service>.yaml`. The pipeline only ever commits to dev.

[`docs/structure.md`](docs/structure.md) is the full map: what is in each
directory, the four rules that explain the layout, and which file to open
depending on what you came to find out.

---

## Running it

**You need two secrets in AWS Secrets Manager before this will work.** This
repository does not create them, because a secret committed is a secret
published:

| secret | holds |
|---|---|
| `kestrel-pay/platform/argocd-admin` | the console password, as a bcrypt hash |
| `kestrel-pay/dev/demo` | a demonstration value the secret store reads |

Without the first, the console password is regenerated on every rebuild.
Without the second, an application stays unhealthy. See
[`docs/runbook.md`](docs/runbook.md) for creating them.

Then:

```bash
./scripts/up.sh       # build everything, point kubectl at it, wait until healthy
./scripts/status.sh   # what exists, and what it is costing
./scripts/down.sh     # destroy everything
```

A rebuild takes about five minutes. The scripts apply and destroy without
prompting, which is right for a person at a keyboard and is why nothing
automated runs them.

**Use the scripts rather than calling Terraform directly.** They are not a
convenience wrapper. Among other things they point the build at an empty
container-registry credential store, because Helm otherwise reads the
operator's own credentials and a stale `ghcr.io` login turns an anonymous pull
of a *public* chart into a 403. Running the two Terraform configurations by
hand fails with `Error locating chart` on any machine that pushes images to a
registry — which was established by cloning this repository fresh and trying.

The delivery controller's console is not exposed to the internet. Reach it by
tunnelling, and log in with the password from the secret above:

```bash
kubectl port-forward -n argocd svc/argo-cd-argocd-server 8080:443
```

The dashboards are reached the same way, on `svc/metrics-grafana` port 80.
Their password is generated rather than committed, so it has to be read out of
the cluster and it changes on every rebuild —
[`docs/runbook.md`](docs/runbook.md) has both commands and says why that one was
left unmanaged.

---

## What it costs

**Between $0.35 and $0.42 an hour while it is up**, measured on 2026-11-19 in
`us-east-1` from two separately billed days. Approximate, region-dependent, and
it will age.

Roughly: $0.10 for the EKS control plane, $0.10–0.12 for three nodes,
$0.10–0.20 for the NAT gateway and data, $0.02 for load balancing.

**The rate is not constant and the reason matters more than the number.** Every
line is billed per hour except address translation, which is charged per
gigabyte — and a rebuild pulls every image through it. So a *short* session
costs more per hour than a long one. The figure rises with activity rather than
with what is installed.

About **$0.89 a month continues after a teardown**: the two secrets and the key
that encrypts them. They are the only things here that survive on purpose.

That is why the platform is built to be parked. Everything in the cluster is
rebuilt from this repository, so tearing it down costs time rather than work.

### One deviation worth naming

The Kubernetes API endpoint is reachable from the internet, restricted to an
explicit list of addresses that has no default and must be supplied on every
build. A private-only endpoint is the right answer for a payments platform
carrying real traffic, and it also needs a bastion or a VPN, which would make
this repository considerably harder to read and run. That is a reviewability
decision rather than a security one, and the allowlist is the seam where it
would be reversed.

The load balancer in front of the routing layer has **no** such restriction.
That and four other limits are listed in
[`docs/architecture.md`](docs/architecture.md) under "What this platform does
not do".

---

## What this is not

A reusable tool. Nothing here should be depended on. The services are
deliberately trivial stubs and are not going to grow toward implementing
payment logic — the interesting content is the configuration and the reasoning
in [`docs/`](docs/), not the application code.
