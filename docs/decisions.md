# Decisions

Every choice in this platform that had a real alternative, with what choosing
it cost.

Entries are appended when the decision is made, not reconstructed once the
work is finished. Reasoning written down while it is still live is more
honest than reasoning remembered.

Each entry carries the same fields:

- **Context** — the situation that forced a choice.
- **Decision** — what was chosen.
- **Why** — the reasoning.
- **Rejected** — the alternative, and why it lost.
- **Accepted cost** — what is worse because of this choice.

The last field is the one that matters. A decision that appears to cost
nothing was not a decision; it was a default that nobody examined.

---

## One NAT gateway for the whole network, not one per zone

**Context.** Nodes run in private subnets, which means they have no route to
the internet of their own. They still need one: to pull container images, to
reach AWS service endpoints, and to talk to anything outside the account. A
NAT gateway provides that route. It is a zonal resource, so the usual pattern
is one per availability zone, each serving the private subnet beside it.

**Decision.** A single NAT gateway, shared by the private subnets in every
zone.

**Why.** A NAT gateway bills an hourly charge whether or not anything sends a
byte through it, plus a charge per gigabyte processed. Running one per zone
multiplies the hourly part by the number of zones, and the hourly part is the
larger share at the traffic volumes this platform sees. Across two zones that
is a meaningful fraction of the total bill for a platform that spends most of
its life idle.

The redundancy being bought is also narrower than it first appears. It
protects outbound internet access during the loss of a single availability
zone. It does nothing for any other failure, and outbound internet is not on
the path that serves user traffic.

**Rejected.** One gateway per zone. It is the correct production answer and
it is what a payments platform carrying real traffic should run, because it
removes a shared dependency between zones. It was rejected here on cost
alone, not because the reasoning against it is strong.

**Accepted cost.** The gateway is a single point of failure that spans zones.
If the zone holding it degrades, every private subnet loses outbound internet,
including subnets in zones that are perfectly healthy. Spreading nodes across
two zones stops protecting against zone failure as far as egress is
concerned, which is a real reduction in what the multi-zone layout is worth.

There is a smaller ongoing cost too: traffic from nodes in the other zone
crosses a zone boundary to reach the gateway, which is billed per gigabyte on
top of the gateway's own processing charge and adds a little latency. At this
scale that is noise, but it grows with traffic, and it grows in the direction
that makes the one-per-zone layout cheaper rather than more expensive.

The seam where this changes is a single setting in the network configuration.

---

## A public API endpoint with an allowlist, not a private one

**Context.** The Kubernetes API server can be reachable only from inside the
network, or also from the internet. A private-only endpoint is what a
payments platform carrying real traffic should run. It also cannot be reached
from a laptop without a bastion host or a VPN into the network first.

**Decision.** The endpoint is reachable from the internet, restricted to an
explicit list of CIDR blocks. Access from inside the network stays enabled as
well, so traffic that originates there never leaves it.

The list has no default value. It must be supplied every time, and the
intended value is the operator's own address.

**Why.** This platform exists to be read and run by people who did not build
it. A bastion is a second piece of infrastructure to build, secure, pay for
and explain, and it demonstrates nothing that the platform is trying to
demonstrate. The cost of that convenience is worth naming out loud rather
than burying, which is what this entry is for.

Leaving the allowlist without a default is the part that carries the weight.
A default would have to be either the whole internet, which is not a
restriction at all, or a guess at an address that will be wrong. Requiring it
means the one setting standing between a public endpoint and an open one
cannot be supplied by accident.

**Rejected.** A private-only endpoint reached through a bastion or a session
manager tunnel. This is the correct production answer and it is what should
be run if any of this data were real. It was rejected on reviewability, not
because the security argument against it is weak — there isn't one.

**Accepted cost.** The API server is reachable from outside the network at
all, which a real payments platform would not accept. Authentication still
stands in front of it and the allowlist is narrow, but the exposure is real
and it is a deliberate deviation from what the rest of this platform argues
for.

There is an operational cost too. An operator whose address changes — a new
network, a reconnected router — loses access to their own cluster and has to
re-apply the configuration with the new address to get it back. That is
mildly annoying by design: the alternative is a wide allowlist that never
needs updating and never protects anything.

---

## Two small burstable nodes, sized for today rather than for later

**Context.** The node group needs an instance type and a count. The obvious
approach is to pick something comfortable and not think about it again, which
tends to mean paying for headroom that nothing uses.

**Decision.** Two on-demand `t3.small` nodes. Both the type and the count are
settings, not literals.

**Why.** The binding constraint turned out not to be price or memory but the
number of pods a node can host. The cluster networking plugin assigns each
pod an address from the node's network interfaces, and the number of
interfaces and addresses per interface is fixed per instance type. A
`t3.small` tops out at eleven pods. What runs here today is about nine per
node across two nodes, so it fits with a little room.

That ceiling disqualifies instances that look competitive on paper. One
single-core type in the same price range offers more memory for the money and
caps at eight pods, which will not hold what is already running. A cheaper
two-core option caps at eight for the same reason. Comparing types on price
and memory alone would have chosen one of them.

Two nodes rather than one is not a cost decision. It exists so that workloads
have somewhere to express anti-affinity and disruption budgets, and neither
means anything on a single node.

**Rejected.** The equivalent ARM instance, which is about nineteen percent
cheaper and identical on cores, memory and pod ceiling. Rejected because the
saving is a few dollars a month and the cost is paid later: every container
image would have to be built for that architecture, and every third-party
image would become an architecture question rather than an assumption.
Importing that constraint into a platform whose interesting content is
elsewhere is a poor trade. The instance type is a setting, so reversing this
is one line.

**Rejected.** Larger instances. They cost two to four times as much for
headroom that nothing currently uses, and buying it now would be sizing
against a guess.

**Accepted cost.** These are burstable instances. They have a fraction of a
core as sustained baseline and run above it on credits, billing for the
surplus rather than throttling. Nothing here works hard enough for that to
show, but the cheapest configuration is cheap partly because it can be
slowed down, and that is the trade rather than a free lunch.

More significantly, two gigabytes a node leaves roughly one and a half
available once the node's own reservations are taken out. That is enough for
what runs today and it will not be enough once a metrics stack is added,
because metrics storage is the memory-hungry component. This configuration is
expected to need resizing at that point, and resizing the node group replaces
it: nodes are drained and rebuilt rather than changed in place. That is
survivable here because everything running is either stateless or rebuilt
from source control, which is precisely why it is acceptable to defer the
decision rather than pre-empt it.

---

## Cluster components are installed explicitly and pinned by version

**Context.** A managed Kubernetes cluster needs a few components before it can
do anything at all: a network plugin that gives pods addresses, a service
proxy, and cluster DNS. There is a widespread assumption that the managed
service installs these itself. The module used here switches that
bootstrapping off, and does so as a fixed decision rather than a setting.

Left undeclared, the result is a cluster that builds successfully and does
not work. Nodes join, report themselves as not ready, and stay that way,
because a node with no network plugin can never become ready. Nothing
reports an error. The node group simply never finishes creating, and the only
symptom is a long wait.

**Decision.** The three components are declared explicitly, each pinned to an
exact version. The network plugin and service proxy are marked as having to
exist before any node is created. Cluster DNS is not, since it runs as
ordinary pods that need a node to run on.

**Why.** Being explicit is not optional here, so the only real choice was
whether to pin the versions or track the newest available. The module tracks
the newest by default.

Tracking the newest means the network plugin can be upgraded underneath a
running cluster as a side effect of applying an unrelated change, and it
means two people applying the same commit weeks apart do not get the same
cluster. On a platform whose entire subject is controlling when and how
things change, having the most safety-critical component in the cluster
update itself unprompted is the wrong default.

**Rejected.** Tracking the newest version automatically. It is less
maintenance and it keeps security patches flowing without anyone thinking
about it, which is a real benefit and the reason it is the default. It was
rejected because an unannounced change to cluster networking is exactly the
class of event this platform is built to make deliberate.

**Accepted cost.** Security updates to these components now require someone
to notice and edit a version. Pinning converts an automatic upgrade into a
maintenance task that can be forgotten, and a forgotten network plugin is a
worse outcome than an unexpected one. This is only defensible alongside a
habit of reviewing the pins, and that habit is the actual cost being accepted
here.

---

## Local state, and a one-string contract between the two configurations

**Context.** The platform is built in two Terraform configurations applied in
order: the first creates the network and cluster, the second installs onto
that cluster. The second has to know where the cluster is. The conventional
answer is a shared remote state backend, with the second configuration
reading the first's outputs directly from its state.

**Decision.** No remote backend. State stays on the operator's machine, and
the two configurations share exactly one value: the cluster's name. The
second configuration looks up everything else it needs from the AWS API at
plan time.

**Why.** Reading another configuration's state creates coupling in three
directions at once. The reader depends on the writer's internal output names,
so renaming an output becomes a breaking change. Both depend on a backend
existing before either can run, which adds a bootstrap step whose only job is
to store the state of the thing that bootstraps everything else. And the
backend itself — a bucket, a lock table — is more infrastructure to create,
tag, secure and eventually destroy.

Looking the cluster up by name removes all three. The contract is one
string. Either configuration can be applied from any machine that can reach
the account, without the other's state being anywhere nearby. And for a
platform operated by one person there is nobody to share state with.

**Rejected.** A remote backend with cross-configuration state reads. This is
the correct answer for a team, and it is what a reviewer who sees no backend
here will assume was overlooked rather than declined — which is the reason
this entry exists. It was rejected because everything it buys is about
collaboration, and there is nothing here to collaborate on.

**Accepted cost.** Local state is a single file on a single machine with no
locking, no versioning and no backup. If it is lost while resources still
exist, Terraform no longer knows about them, and the resources keep running
and keep billing with nothing that can cleanly remove them. The whole
park-and-resume workflow rests on that file surviving between sessions, and
nothing here protects it beyond the operator's own care.

That is an acceptable risk for one person and an unacceptable one for two.
The moment a second operator appears, this decision is reversed and a backend
becomes the first thing added.

---

## Providers are pinned exactly, Terraform itself only to a minor version

**Context.** Everything here is pinned so that two people running the same
commit get the same result. Applied literally that includes Terraform itself,
which was originally pinned to an exact patch release.

Eleven days later the tool updated itself by one patch version and every
configuration refused to run. Nothing had changed about the infrastructure or
the intent; the pin had simply gone stale.

**Decision.** Provider versions stay exact. Terraform's own constraint allows
patch releases and rejects minor and major ones.

**Why.** The two are pinned for different reasons and it was a mistake to
treat them the same. Provider versions decide what resources get created and
how, so a difference there is a difference in the infrastructure, and exact
pinning is what makes the output reproducible. Terraform's patch releases fix
bugs in the tool and do not change what a configuration produces. Refusing
them buys no reproducibility at all, and the price is that routine tool
updates break the repository until someone edits it.

A constraint that has to be edited on a schedule unrelated to the work stops
being read as a decision and starts being read as an obstacle, and the usual
response is to widen it in a hurry without thinking. Better to draw the line
where it means something.

**Rejected.** Keeping the exact patch pin and updating it each time. It is
defensible for a team that ships a pinned toolchain to every machine, because
then the constraint documents something real. Here there is no such
mechanism, so the pin documents nothing and only interrupts.

**Rejected.** Dropping the constraint entirely. A major version of Terraform
can change language behaviour, and finding that out mid-apply on a cluster is
worse than being told up front.

**Accepted cost.** Two people on different patch releases can now get
different tool behaviour, which in rare cases means different results from the
same commit — bug fixes and deprecation warnings are exactly the kind of thing
that shifts between patches. That is a real, if small, loss of the property
being claimed, and it is the price of a constraint that survives contact with
a machine that updates itself.
