# Architecture

What runs where, which system owns which resources, and where the boundaries
between them sit.

This describes what is built today. The platform provisions a cluster and
hands it over to a delivery controller; it does not yet run any application.
That is the intended stopping point for this stage, not an omission —
the handover is the hard part, and it is finished.

## The shape of it

![Platform architecture](diagrams/platform-architecture.png)

A single AWS region holds one VPC spanning two availability zones. Public
subnets carry the internet gateway and a NAT gateway; private subnets carry
everything else. The managed Kubernetes control plane sits outside the VPC's
subnets but is reachable from them, and two small instances run as worker
nodes in the private subnets.

Inside the cluster, one namespace holds the delivery controller and the single
object that points it at this repository. Nothing else is deployed.

Solid outlines in the diagrams are built. Dashed outlines are planned.

## The boundary that matters most

Three systems create things here, and each owns a disjoint set. Nothing has
two owners, and that is deliberate.

**The provisioning tooling owns AWS, and exactly three objects inside the
cluster:** the namespace, the delivery controller's installation, and one
Application resource pointing at a path in this repository. That is the whole
list. It is short because every object it owns is an object the controller
must not also manage.

**The delivery controller owns everything else inside the cluster.** Today
that is nothing, because the path it watches holds only a placeholder. From
the moment something is committed there, the controller creates it, keeps it
matching what is committed, and removes it when it is deleted from the
repository.

**Neither owns a third category**, and this is the one that causes trouble.
AWS creates some resources on its own behalf — the instances behind a managed
node group come from an auto-scaling group, not from the provisioning tooling,
along with their volumes and network interfaces. Later, controllers inside the
cluster will ask AWS for load balancers. None of these appear in any state
file.

Why the three-way split is worth drawing: a resource claimed by two systems is
reconciled by two systems. The symptom is an Application that flips between
in-sync and out-of-sync forever, and the cause is invisible from either side.
Keeping the provisioning tooling's footprint inside the cluster to three
objects is what prevents it.

## How a change reaches the cluster

![Release paths](diagrams/release-paths.png)

The controller polls this repository and applies what it finds. Continuous
integration never reaches the cluster: it builds an image, pushes it, and
commits the new tag back here. The arrow always points outward from the
cluster to the repository, never inward. That is what makes the repository
authoritative rather than merely a starting point — self-healing is on, so a
change made directly against the cluster is reverted rather than kept.

The two workloads this platform is built for are released differently, and the
second diagram is mostly about why. One is stateless and can have two versions
serving at once while traffic is shifted gradually and measured. The other
pays merchants, and two versions touching the same batch means paying someone
twice — so it is released by making sure only one version can ever be active,
and only between runs. The specific thresholds and steps are not yet chosen.

## Identity

Workloads get AWS permissions through the cluster's own identity provider
rather than through credentials or through the permissions attached to the
nodes they happen to run on. A role trusts that provider, with a condition
naming one namespace and one service account; a pod running under that service
account receives a short-lived token and exchanges it for the role.

Pinning both the namespace and the service account name in that condition is
the part that matters. A wildcard would let any workload in the cluster assume
the role, which turns a narrow grant into a cluster-wide one without looking
any different.

Two coarser roles exist and are unavoidable: one the managed service uses to
run the control plane, and one the nodes use to pull images and manage
networking. Those are shared by everything on a node, which is exactly why
per-workload roles exist for anything more specific.

## Cost, and what is tagged

Running costs about **$0.19 an hour** — roughly $0.10 for the control plane,
$0.045 for a single NAT gateway, $0.042 for two small nodes. Around $140 a
month if left up, which is why the platform is built to be torn down between
working sessions and rebuilt from this repository. Everything inside the
cluster is reconciled from source control, so rebuilding costs time rather
than work.

Every resource the provisioning tooling creates carries a project tag applied
once at the provider level rather than repeated per resource. Two categories
need more than that:

**Instances, volumes and network interfaces** are launched from a template
rather than created directly, so a provider-level default never reaches them.
The template stamps the tag on what it launches, which has to be configured
deliberately. Missing it leaves the compute — the second largest line on the
bill — absent from any report grouped by project.

**Load balancers created by an ingress controller** will have the same
problem when they appear, and the controller will need its own tagging
configuration. Untagged spend is invisible spend, and a cost report with a
hole in it is worse than none, because it looks complete.

## What is deliberately absent

No remote state: state is a local file, and the two configurations share only
the cluster's name rather than reading each other's state. No ingress, no
secrets management, no database, no monitoring, no application. Each is
deferred rather than forgotten.

The reasoning behind these, and behind everything above, is in
[decisions.md](decisions.md) — including the costs accepted along the way.

## Editing the diagrams

The source is [`diagrams/kestrel-pay-architecture.drawio`](diagrams/kestrel-pay-architecture.drawio),
a two-page drawing. Open it with [draw.io](https://www.drawio.com), change what
has moved, and export each page again over the images above. A drawing file is
not an image, which is why the exported pictures are committed alongside it.
