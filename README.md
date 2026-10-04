# Kestrel Pay — GitOps delivery platform

A Kubernetes delivery platform for a payments company that does not exist,
built to work through one problem that most reference architectures step
around: what to do when two workloads in the same system cannot be released
the same way.

The company and its services are invented. [`scenario.md`](scenario.md) says
so on its first line and describes the two workloads in full.

## The problem it exists to answer

`payments-api` is a stateless HTTP service. Two versions can serve traffic at
once without interfering, a small share of traffic is a small share of the
harm, and a bad release shows up in the error rate within seconds. It can be
released gradually: send the new version a slice of live traffic, measure, and
either widen the slice or take it away.

`settlement-worker` is a batch job that pays merchants. Its output is money
leaving an account. Two versions running against the same batch both decide a
payout is owed, and the merchant is paid twice — and the second payment has
already left before anyone notices. There is no small slice, and rolling back
is not a remedy.

Gradual release depends on assumptions so reliably true of web services that
they usually go unstated. The worker satisfies none of them. A platform that
applies one release strategy to both has misread at least one of them, and the
difference between the two is what this repository is about.

## What exists today

The provisioning layer and the handover to GitOps:

- A VPC across two availability zones, and an EKS cluster with a managed node
  group in private subnets
- Workload identity, so a pod can assume an AWS role through its service
  account
- Argo CD, installed by Terraform, pointed at [`argocd/root/`](argocd/root/)
  in this repository with automatic sync, prune, and self-heal on

That last part is the end of the provisioning story and the start of
everything else: from there, what runs in the cluster is decided by what is
committed here rather than by what someone applies from a workstation.

**Nothing is deployed through it yet.** The watched path holds a placeholder,
the controller reports healthy against an empty set, and the two services
above are not built. Ingress, secrets management, observability and
progressive delivery come later. The diagrams mark planned components with
dashed outlines so it is clear which is which.

## Reading it

- [`docs/architecture.md`](docs/architecture.md) — the system as built, with
  diagrams, and where the ownership boundaries sit
- [`docs/decisions.md`](docs/decisions.md) — every choice that had a real
  alternative, what was rejected, and what the choice costs. Each entry
  carries an accepted cost, because a decision that appears to cost nothing
  was not a decision
- [`scenario.md`](scenario.md) — the invented scenario, in full

## Running it

Two Terraform configurations, applied in order. They share one value — the
cluster name — and are otherwise independent; the second finds the cluster
through the AWS API rather than by reading the first one's state.

```bash
cd terraform/cluster
terraform init
terraform apply \
  -var 'cluster_name=kestrel-pay-dev' \
  -var "endpoint_allowed_cidrs=[\"$(curl -s https://checkip.amazonaws.com)/32\"]"

aws eks update-kubeconfig --name kestrel-pay-dev --region us-east-1 --alias kestrel-pay-dev

cd ../platform
terraform init
terraform apply -var 'cluster_name=kestrel-pay-dev'
```

Reach the delivery controller by tunnelling to it — nothing is exposed to the
internet:

```bash
kubectl port-forward -n argocd svc/argo-cd-argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then open `https://localhost:8080` as `admin`. The certificate is self-signed
and the password is regenerated every time the cluster is built.

Tear down in the opposite order: `platform` first, then `cluster`.

## What it costs, and the trade it makes

About **$0.19 an hour** while it is up — roughly $0.10 for the EKS control
plane, $0.045 for a single NAT gateway, and $0.042 for two small nodes. That
is around $140 a month if left running, which is why it is built to be torn
down between working sessions and rebuilt from this repository.

One deviation is worth naming rather than burying. The Kubernetes API
endpoint is reachable from the internet, restricted to an explicit list of
addresses that has no default and must be supplied on every apply. A
private-only endpoint is the right answer for a payments platform carrying
real traffic, and it also needs a bastion or a VPN to operate, which makes
this repository considerably harder to read and run. That is a reviewability
decision, not a security one, and the allowlist is the seam where it would be
reversed.

## What this is not

A reusable tool. It is a reference platform — a set of decisions encoded as
configuration, with the reasoning written down beside them. Nothing here is
meant to be depended on, and the services are deliberately trivial stubs: the
interesting content is in `docs/`, not in the application code.
