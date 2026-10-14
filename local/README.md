# Local cluster

A three-node cluster on your own machine, for work that does not need AWS:
writing manifests, checking a chart renders, learning how something behaves
before paying for it.

```bash
kind create cluster --config local/kind.yaml
kubectl config use-context kind-kestrel-pay-local
kubectl get nodes          # three, all Ready
```

Tear it down with `kind delete cluster --name kestrel-pay-local`. It costs
nothing to keep, but it holds memory and file handles, so delete it when you
are done.

The Kubernetes version matches the managed cluster, and the node image is
pinned by digest rather than tag — those tags get republished, so a digest is
the only reference that means one specific image.

## What it cannot reproduce

This is the part worth reading before trusting it.

**Workload identity.** There is no OIDC provider and no IAM. A pod cannot
assume an AWS role here, so anything that reads a secret or calls an AWS API
either has to be stubbed or will simply fail. This is the single biggest
difference and the one most likely to catch you out, because the manifests
look identical.

**Load balancers.** Nothing provisions one. A Service of type LoadBalancer
stays pending forever. Traffic reaches the cluster only through the two
mapped host ports, which is why the control plane carries the ingress label
and why ports 80 and 443 are bound to it.

**Storage.** There is no EBS and no CSI driver. Volumes are local
directories, so they do not survive the node, and nothing exercises the
attach and detach behaviour that real volumes have.

**Everything around the cluster.** No real DNS, no certificates that anything
trusts, no node autoscaling, no spot interruptions, no availability zones —
the three "nodes" are containers on one kernel, so a test of zone failure
tests nothing.

What it does reproduce faithfully is the Kubernetes API itself: scheduling,
RBAC, admission, and whether your manifests are valid and your controllers
behave. That is most of the day-to-day work, which is why it is here.

## If creation fails

A multi-node cluster needs more file watches than a desktop usually allows.
If nodes join and then go unhealthy, raise the limits:

```bash
echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512" \
  | sudo tee /etc/sysctl.d/99-kind.conf
sudo sysctl --system
```

Ports 80 and 443 must also be free on the host.
