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

## How to read this file

**It is append-only and in chronological order.** Entries are never edited to
match what came later, because the point of the record is what was known at the
time. That has two consequences a reader needs before starting.

**Later entries supersede earlier ones without saying so in the earlier one.**
The node sizing is decided three times — two small instances, then two larger,
then three — and only the last is current. The same is true of chart fetching,
of what the per-node agent overhead is, and of several cost figures. **When two
entries disagree, the later one is current.** Where a later entry knows it is
reversing an earlier one, it says so; the earlier one is left alone.

**Figures are correct as of the entry that states them.** Every cost number in
this file predates the measurement in `architecture.md`, which was taken on
2026-11-19 from two separately billed days and is the current one. The earlier
figures are kept because the reasoning that produced them is part of the record
— including the fact that they were systematically low, which is itself an
entry here.

**The field structure is Context, Decision, Why, Rejected, Accepted cost.** The
later entries loosen it, and some are closer to essays. The accepted cost is
always present, because an entry without one was not a decision.

A reader wanting only the current state of the platform should read
[architecture.md](architecture.md) instead. This file is why, not what.
---

## Two configurations applied in order, not one

**Context.** The platform is built in two steps: AWS infrastructure first, then
the delivery controller installed onto the cluster that step produced. Those
could be one configuration applied once, or two applied in order.

One configuration is tempting because it is a single command. The obstacle is
that the tooling has to be told how to reach the cluster before it knows the
cluster will exist. Connection settings are read before anything is created,
so the first run has nothing to point at. The usual way out is to narrow the
first run to a subset of resources, then run it again unrestricted.

**Decision.** Two configurations, applied in order, with separate state. They
share one value: the cluster's name.

**Why.** The split removes the ordering problem rather than working around it.
By the time the second configuration runs, the cluster exists and can be
looked up like any other resource.

More importantly, the boundary between them is the same boundary that matters
everywhere else in this platform. The first owns AWS. The second owns the
handover to the delivery controller, and nothing beyond it. Someone reading
the directory listing can see where that line falls before reading any code,
which is worth more than saving a command.

**Rejected.** A single configuration with the first run narrowed to a subset.
It works, and plenty of projects do it. It was rejected because narrowing a
run is a debugging tool, and making it a required step teaches anyone copying
the pattern that this is normal. It also has to be explained every time
somebody new stands the platform up, and a step that must be explained is a
step that will eventually be skipped.

**Accepted cost.** Two applies and two destroys, in opposite orders, where
there could have been one of each. Anyone running this has to know the order
and get it right — the second configuration fails confusingly if the first has
not run, and a teardown in the wrong order strands objects inside a cluster
that is being deleted underneath them. That knowledge now lives in the
lifecycle scripts, which is a mitigation rather than a cure: the ordering is
still real, and anyone bypassing the scripts has to know it.

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

---

## The controller is installed by the provisioning tool, not by itself

**Context.** Something has to create the component that everything else in the
cluster is then managed by. That component cannot create itself, so the
question is what does.

**Decision.** The provisioning tool installs it, along with its namespace and
the single resource that points it at this repository. Those three objects are
the only things in the cluster that the provisioning tool owns. Everything
else arrives by being committed.

**Why.** The boundary is worth being able to see. Three objects created from
outside, everything else created from source control, and no object with two
owners. A resource claimed by both would be reconciled by both, and the
symptom is a controller that oscillates between in-sync and out-of-sync
permanently, which reads as a bug in something else entirely.

**Rejected.** A bootstrap script that installs the controller and then hands
it a definition of itself, so that it manages its own upgrades. It is
appealing because it removes the last thing done from outside. It is also
self-referential in the worst place: a bad change to the controller's own
configuration can leave the thing that would repair it unable to start, and
recovery then means going around it with the tooling it was supposed to
replace. For a bootstrap component, ownership from outside is the safer side
of that trade.

**Accepted cost.** The controller cannot upgrade itself. Moving it to a new
version is a change to the provisioning configuration and an apply from a
workstation, not a commit. That is a genuine inconsistency in a platform whose
whole argument is that changes arrive through commits, and it is the price of
not making the component that fixes things depend on itself being healthy.

---

## Creating the first custom resource, when nothing yet defines its type

**Context.** The resource that points the controller at this repository is of
a type the controller itself defines. Until the controller is installed, the
type does not exist. Both need to happen in one run, because a platform that
takes two runs to stand up has a manual step in the middle of its bootstrap.

**Decision.** The resource is delivered as a one-template chart, applied by the
same tool that installs the controller, ordered explicitly behind it.

**Why.** The obvious approach — declaring it as a Kubernetes resource in the
provisioning configuration — cannot work here, and the reason is worth
knowing. That method reads the type's definition from a live cluster while
planning, so the type must already exist before a plan can even be produced.
Declaring the dependency does not help: the obstacle is at planning time and
dependencies only order the work of applying.

Templating renders locally and asks the cluster nothing until it applies. That
turns an impossible ordering into an expressible one: finish installing the
controller, by which point the type is established, then apply the resource.

**Rejected.** Adding the resource to the controller's own installation as an
extra manifest. It works and needs no additional machinery. It was rejected
because it erases the boundary this platform is trying to make visible — the
resource stops being its own object with its own owner and becomes a field
inside the controller's installation, so the count of externally-owned objects
reads as two rather than three, and changing the resource means changing the
controller's release.

**Rejected.** A third-party plugin that applies manifests without consulting
the cluster while planning. It has exactly the needed property. It was
rejected on supply: the maintained option is pre-release, and the older one is
the less active lineage. Putting an unvetted dependency in the bootstrap path
is a poor trade for a problem already solvable with what is here.

**Rejected.** Two separate runs, or narrowing the first run to a subset of
resources. Both work and both make standing this up a procedure to remember
rather than a command to run.

**Accepted cost.** A chart exists whose only purpose is to carry one manifest,
which is indirection that has to be explained to anyone reading the
configuration — so the explanation lives in the template itself rather than
only in this log. The ordering is also declared rather than derived, which
means it is invisible to anything checking the configuration for correctness
and would be easy to remove by accident while tidying.

---

## Environments are namespaces in one cluster, not clusters of their own

**Context.** Environments have to be separated somehow. The options are
namespaces inside one cluster, a cluster each, or an account each. The usual
reason given for choosing namespaces is cost, and in this case that reason
does not survive contact with the numbers.

A second cluster costs about $1.90 per working session. This
platform is torn down between sessions, so the monthly figure everyone quotes
is a figure nobody pays. Cost is not what decides this.

**Decision.** Environments are namespaces within a single cluster. Everything
below the namespace — the Kubernetes version, the node pool, the custom
resource definitions, the admission chain, the ingress controller — is shared.

**Why.** Complexity, and specifically where it would land. A delivery
controller managing clusters other than its own needs credentials for them.
The mechanism by which secrets reach this platform is being built in the same
stretch of work; making it a prerequisite for reaching the other environments
at all would stack an unsolved problem on top of another unsolved problem.
Each additional cluster also adds a teardown of thirteen to twenty-seven
minutes and another thing for the lifecycle scripts to know about.

**Rejected: a cluster per environment.** Better isolation in every respect,
and not rejected on money. Rejected because the complexity it adds lands
precisely where this stage is weakest.

**Rejected: an account per environment.** This is the right answer for a
company actually moving money, and it is the only one of the three that is a
security boundary rather than an organisational one. It is out of reach for a
platform run by one person, and it is named here rather than left unmentioned
so that the chosen option is not mistaken for the correct one.

**Accepted cost.** A Kubernetes version upgrade cannot be tested in one
environment before another, because there is only one control plane. For a
platform whose subject is release safety, that is a real concession and not a
comfortable one. A bad cluster-wide object — a custom resource definition, an
admission webhook — reaches every environment at once.

And a namespace is not a security boundary. It separates names and applies
quotas; it does not stop a workload determined to reach another. Two
namespaces named after environments do not isolate those environments, and
reading this as though they do would be a mistake the names actively invite.

---

## Components are listed one file at a time, not generated from the tree

**Context.** The resource that points the controller at this repository brings
up further resources, one per component. Those can be written out as files, or
produced from the directory layout by a generator the controller provides.

**Decision.** One file per component, listed explicitly.

**Why.** Count first. By the end of the planned work the inventory is about a
dozen: two shared platform components, two environments, two services in each,
a metrics stack, a rollout controller, and the analysis it reads. A generator
earns its keep when adding the fiftieth of something is tedious, and that point
is never reached here.

At this size an explicit list is also the better answer to the question "what
is deployed", because listing a directory answers it directly. With a generator
you have to know the generator's rules and then work out what they currently
match, which is a second thing that can be wrong: a component can fail to
appear because a pattern did not match it, and a component that is silently
absent is harder to notice than a file that is obviously missing.

**Rejected: a generator over the directory layout.** Concise, and adding a
component becomes free. Rejected for making the inventory invisible at exactly
the scale where the inventory is small enough to read.

**Accepted cost.** Repetition, and it compounds. Each component is a
near-identical block differing in a name and a path, and the count grows with
every service and every environment. The point at which this stops being
acceptable is real and will arrive: a third environment roughly doubles the
files, and that is the moment to revisit this rather than endure it.

---

## Traefik for ingress, and the portable routing API rather than its own

**Context.** Something has to accept a request from outside the cluster. The
familiar choice for years was the community NGINX ingress controller.

**Decision.** Traefik, driven through the portable routing API rather than
through the older ingress object or through Traefik's own resource types.

**Why.** The familiar choice is gone. That project was retired in March 2026
and is archived and unpatched, and the successor it designated was retired too.
An unpatched component on the path every request takes is not a default to
reach for out of habit.

Traefik is actively maintained, implements the portable routing API, and is
supported by the rollout controller a later stage of this platform needs for
gradual traffic shifting — which is the real constraint. Choosing an ingress
controller here that could not shift traffic by weight would mean replacing it
later, and replacing the component every request passes through is not a change
anyone wants to discover they have to make.

The portable API rather than the older ingress object, because weighted routing
is expressible in it directly instead of through vendor-specific annotations,
and because the older object is the one being retired. Traefik's own resource
types would work equally well today and would tie every routing definition in
this repository to this one controller.

**Rejected: an AWS-managed load balancer controller as the ingress layer.** It
is the cloud provider's own recommendation and produces better balancers.
Rejected at this point because it needs a workload identity binding of its own,
which is the mechanism being built in the same stretch of work, and taking it
here would mean building that mechanism twice or reordering everything around
it. Recorded as the production answer and deferred.

**Rejected: the newest chart release.** A major version was published the same
day this was pinned, with breaking changes in its own release notes and a
minimum Kubernetes version two minors higher. The version pinned here carries
the identical controller and had a week in the wild.

**Accepted cost.** The portable API's type definitions do not ship with the
controller's chart — checked by unpacking it — so they come from a separate
source that has to be applied first, which is one more thing in the bootstrap
path and one more version to keep in step. The definitions are also referenced
from the upstream project at a fixed tag rather than copied here, which means
this platform depends on that repository staying reachable at that tag.

And Traefik is less widely known than the thing it replaces. Anyone arriving at
this repository expecting the familiar controller has something new to learn
before they can read the routing.

---

## A load balancer created from inside the cluster is tagged by the request

**Context.** Asking for an externally reachable service produces a load
balancer in AWS. The provisioning tool never sees that resource, so the tag
defaults set at the provider level cannot reach it. This is the first resource
in this platform created by something running inside the cluster.

**Decision.** The service carries an annotation listing the tags, and the cloud
controller already present in a managed cluster applies them when it creates
the balancer.

**Why.** It is the only mechanism that exists for this. Verified against the
controller's documentation rather than assumed, because the shape of the
mistake was already familiar: the compute instances in this platform turned out
untagged for the same reason, having been launched from a template whose tag
block is data rather than resource configuration. A thing created on your
behalf inherits nothing from the tool that asked for it, and the request has to
carry the tags itself.

Nothing extra needs installing. A service asking for a balancer is handled by
the controller that ships with a managed cluster, and the subnet tags already
in place are what it reads when deciding where to put it.

**Rejected: installing the newer load balancer controller instead.** It is the
cloud provider's recommendation, it produces network rather than classic
balancers, and it is the better long-term answer. Deferred for the reason given
in the entry above.

**Accepted cost.** The tags are a string in a values file, matched by eye
against the tags the provisioning tool applies elsewhere. Nothing checks that
the two agree, and a typo produces a resource that is tagged, looks tagged, and
is still missing from the cost report. The balancer is also billed by the hour
whether or not anything is using it, and adds roughly thirteen percent to what
this platform costs to run.

---

## The secrets operator's identity is held in AWS, not annotated in the cluster

**Context.** An operator inside the cluster reads secrets out of AWS so that no
secret value is ever committed. For that it needs AWS permissions, and the
usual way to grant them is to annotate its service account with the identifier
of a role it may assume.

That identifier contains the AWS account number. The service account is an
object inside the cluster, so the delivery controller owns it, so it has to be
committed — and this repository is public and carries a rule that no account
identifier appears in it anywhere. The two requirements are in direct conflict.

**Decision.** The newer binding mechanism, where the association is a record
held in AWS naming the cluster, a namespace and a service account name, and the
role is named only on the AWS side. The service account carries no annotation.

**Why.** Neither of the conflicting rules should give. That no account
identifier is committed is what makes this repository publishable. That the
controller applies everything inside the cluster is the point of this stage of
the work.

The AWS-side record resolves it without weakening either, because all three
keys it is written against — a cluster name, a namespace, a service account
name — are ordinary strings that disclose nothing. An account number on the AWS
side is not a disclosure; it is the account you are already authenticated to.

A second benefit was not the reason but is the larger one. The older mechanism
names the cluster's identity provider in its trust policy, and that provider is
regenerated with a new identifier every time the cluster is rebuilt — which is
exactly how the hand-made binding earlier in this platform's life stopped
working. The newer mechanism's trust policy names a fixed service principal, so
there is nothing cluster-specific in it to go stale. The cluster-specific part
moves into the association record, which the provisioning tool recreates from
the cluster name it already holds. The binding survives a rebuild because the
thing that used to go stale is no longer there, which is a better outcome than
deriving it correctly.

It also settles an ownership question rather than answering it. The service
account was the one object straddling the line between what the provisioning
tool owns and what the controller owns. With no annotation on it, the service
account is wholly the controller's and the role and association are wholly the
provisioning tool's. Nothing is half-owned.

**Rejected: annotating the service account with the role identifier.** The
standard answer and the one every tutorial shows. Rejected because it puts an
account number in a public repository, and every way of hiding it is worse than
the problem: having the provisioning tool patch a service account it does not
own moves an ownership line this stage of the work promised not to move, and
supplying the value from outside the repository means the cluster's contents are
no longer decided by what is committed, which is the claim being made here.

**Rejected: giving the operator a stored access key.** Would work in an
afternoon, and is how this is done on clusters that are not on a cloud
provider. Rejected because a credential able to fetch every secret would then be
the one secret with nowhere to come from, bottoming the whole mechanism out in a
key somebody places by hand and rotates by hand.

**Rejected: a broad read permission over the account's secrets.** The role is
scoped to a single name prefix, and listing secrets is absent from it
altogether. The operator is told which secrets to fetch by what is committed, so
it never needs to discover them, and a role that can enumerate an account's
secrets tells an attacker what is worth going after even when it cannot read
any of them.

**What the identity may actually do.** Two actions: fetch a secret's value,
and describe a secret in order to notice that its value has moved on. Listing
secrets is absent deliberately. The operator is told which secrets to fetch by
what is committed, so it never needs to discover them — and a role that can
enumerate an account's secrets tells an attacker what is worth going after even
when it cannot read any of them.

The resource pattern ends in a wildcard, which is not laxness that crept in.
Every secret identifier in this service ends in six random characters assigned
at creation, so the exact identifier cannot be known before the secret exists.
The pattern is built from values this configuration already holds rather than
written out by hand.

**Accepted cost, and there are three.**

Portability. This mechanism belongs to one cloud provider's managed Kubernetes
and has no equivalent elsewhere. The local cluster in this repository cannot
reproduce it, which widens a gap between local and real that was already
acknowledged.

One identity for the whole cluster. The annotation-based mechanism lets the
operator assume a different role per secret store, so one namespace's store can
be scoped to that namespace's secrets. This one cannot — the operator's own
documentation says so — so every store reads through the same role and the only
scoping available is the name pattern in that role's policy. With two
environments sharing a cluster whose boundary is already not a security
boundary, that is consistent rather than worse. On a platform where
environments were genuinely separated it would be the wrong shape. A workload
needing its own AWS permissions gets its own association; it does not get them
through the operator.

Two more pods. The mechanism needs an agent on every node, and the node pool
has a hard ceiling of eleven pods per node for networking reasons. Together
with the operator's three deployments this takes the cluster from fourteen pods
to nineteen of a possible twenty-two. The next component added is where that
ceiling starts deciding things.

---

## The controller's own password comes from AWS, merged into its existing secret

**Context.** The delivery controller generates an admin password on first
start and keeps it in a secret of its own. Because this platform is torn down
between working sessions to stop paying for it, every resume is a first start,
so the password was different every time and had to be read out of the cluster
before anyone could log in.

**Decision.** A bcrypt hash of a chosen password is held in AWS, and the
secrets operator writes it into the controller's existing secret, merging two
keys rather than owning the secret.

**Why this secret and not an invented one.** Something had to demonstrate that
secrets reach this cluster from AWS, and the obvious move is to invent a secret
for the purpose. This one is a real problem the platform had already run into,
which reads completely differently from a placeholder. Nothing was contrived to
create the need.

**Why merge rather than own.** The controller's secret also holds the key it
signs sessions with and the certificate it serves with. Taking ownership would
mean replacing those too — logging everyone out and breaking the serving
certificate — so only the two password keys are written and every other key in
that secret is left alone.

There is a related finding worth recording because it changed the plan. The
installation does not write the password key at all: with no password supplied,
the rendered secret has no data section whatsoever, and the server fills in its
own password, signing key and certificate on first start. So the installation
and the operator are not fighting over the same key, which is what made merging
safe. Had the chart written a password, the two would have overwritten each
other on every apply.

**Why a hash and not the password.** The controller only ever compares against
a hash, so the password itself does not need to exist anywhere in this
platform. It lives in the operator's password manager. The practical effect is
that the operator's read permission — which covers every secret under this
platform's prefix — cannot be used to recover the password, only the hash.

**Rejected: supplying the hash as an installation value.** This was the plan of
record and it does not work. That value is resolved by the provisioning tool
when it installs the controller, which means the provisioning tool would have
to read the secret from AWS and hold it in its state file. The secrets operator
could never feed it, so the mechanism built for exactly this purpose would go
unused on the one credential that most needed it.

**Rejected: leaving the generated password and printing it at startup.** What
the platform did before, and it works. Rejected because the password changing
on every resume is the problem, and because a credential that has to be read
out of the cluster before use cannot be given to anyone who does not already
have cluster access.

**Accepted cost.** Logging into the delivery controller now depends on an
operator that the delivery controller itself deploys. If the operator is
broken, the console you would use to investigate is the thing you cannot reach.
It is a degradation rather than a lockout — every recovery step runs through
`kubectl` and none needs the console — and that is the only reason the trade is
acceptable. The recovery path is written down in `docs/runbook.md` rather than
left to be worked out at the time, because a recovery path discovered under
pressure is not a recovery path.

A second cost, smaller and concrete: the password is stable across rebuilds,
which is the point, and also means a password leaked once stays leaked until
somebody rotates it. Previously a teardown rotated it by accident. Rotation is
now a deliberate act, and the runbook has the procedure.

---

## Environment values live outside the chart, reached by declaring the repository twice

**Context.** Every difference between environments is supposed to live in one
directory per environment and nowhere else, which puts those values outside the
chart that consumes them. The delivery controller resolves a chart's value files
relative to the chart directory and refuses paths outside it, so the obvious
reference does not work.

**Decision.** Declare two sources on the same Application: the chart, and the
same repository again, marked as a reference that value paths can be written
against. Both point at this repository. The second exists only so the first can
reach outside its own directory.

**Why.** It is the supported route, and the alternatives both break something
that matters more than the awkwardness. Moving the values into the chart
collapses the separation the layout exists to create — the chart stops being
identical across environments, and the claim that one environment resembles
another stops being checkable. Copying the values into each Application puts
environment differences in two places, which is the same failure wearing a
different hat.

**Rejected: values inside the chart, with environments selected by a flag.**
Simpler to read and needs no second source. Rejected because it makes the chart
environment-aware, and a chart that knows which environment it is in can drift
between them in ways nothing detects.

**Accepted cost.** It reads as indirection, because it is. Anyone meeting this
for the first time sees a repository listed twice in one Application and has to
be told why, so the explanation lives next to it rather than only here. It is
also a mechanism specific to this controller rather than a general property of
the templating tool, so the layout is not portable to a different delivery tool
without rework.

---

## Custom resource types are schema-checked against the cluster, not a catalog

**Context.** Every rendered manifest is supposed to pass schema validation
before a change is considered done. For built-in Kubernetes types the schemas
are published and the check is routine. Custom types are not built in, and
their schemas have to come from somewhere.

**Decision.** The offline validator checks everything it can against the
published catalog of community-contributed schemas. The custom resource types
are additionally checked by sending them to the cluster's own API server as a
dry run, which validates them against the type definitions actually installed
and applies nothing.

**Why.** The catalog turned out to contain a schema the validator could not
load. The error it reports — that no schema exists for the type — points at the
wrong thing entirely, since the schema plainly exists and fetches fine. Narrowed
down by bisection: one branch of that schema declares a boolean where a schema
object belongs, which the validator rejects at load time and reports as absence.

Rather than work around a defect in a transcription of the type definition, the
check moved to the definition itself. The API server holds the authoritative
schema for a type installed in that cluster, and a dry run is the same
validation a real apply would perform. That is a stronger check than the one it
replaces, not a weaker substitute for it.

**Rejected: suppressing the missing-schema error.** One flag, and the whole
class of check silently stops applying — including to types where it would have
caught something.

**Rejected: committing a corrected copy of the schema.** Fixes today's problem
and creates a vendored file that must be kept in step with a project that
publishes its own, which is the trade this platform refuses elsewhere.

**Rejected: validating against an older version of the schema that does load.**
Would pass, and would be checking the wrong contract. A check that passes
against something other than what is deployed is worse than no check, because it
reports confidence it has not earned.

**Accepted cost.** Part of the validation now requires a running cluster, so it
cannot all run offline or in a build that has no cluster access — and this
platform deliberately gives its build pipeline no route to the cluster. So the
custom-type check is something an operator runs, not something a pipeline
enforces, and it can therefore be skipped by someone in a hurry. The offline
half still runs anywhere and still covers every built-in type.

**Postscript, five days later.** The catalog was fixed upstream. The same
schema that could not be loaded now loads, and the offline validator passes on
every type here without help. The specific problem this decision was made
about lasted less than a week.

That is worth leaving in rather than quietly deleting, because the conclusion
survives the fix and is strengthened by it. A community-maintained
transcription of a type definition is a moving target: it was wrong, it is now
right, and nothing in this repository would have noticed either event. The
cluster's own copy of the definition cannot drift from the definition the
cluster enforces, because it is the same object. So the dry run stays — no
longer as a workaround for a defect, but as the check that is authoritative
about the thing being validated. The offline validator stays too, because it
runs anywhere and catches the ordinary mistakes faster.

---

## Nodes are made larger because the pod ceiling was reached, not because of what comes next

**Context.** The cluster networking plugin caps how many pods a node can run by
how many IP addresses the instance type can hold, and the type in use allows
eleven. Two nodes, twenty-two slots, nineteen in use. Three free, with two
services about to be added across two environments.

**Decision.** Two nodes of the next size up — thirty-four slots.

**Why, and why now rather than earlier.** Three free slots cannot hold two
services in two environments, and one of those services is the one whose entire
purpose is to scale by replica count. Sizing was correct when it was chosen and
has been outgrown; that is the normal life of a sizing decision rather than a
mistake being corrected.

**Rejected: a third node of the current size.** Cheaper, and it looks like the
obvious answer. Thirty-three slots against thirty-four for two thirds of the
extra cost. Rejected because each node arrives already owing three pods — it
runs its own networking agent, service proxy and identity agent (**this became
four when the metrics exporter was added a phase later; the arithmetic below is
as it stood at the time**) — so the
thirty-three is really twenty-five usable against the larger pair's
thirty-four. Per usable slot it is the worse buy, and the arithmetic is only
visible if you remember that per-node components scale with nodes.

**Rejected: raising the address limit instead of the instance size.** The
networking plugin can assign each interface a block of sixteen addresses rather
than single addresses, which lifts the ceiling to around a hundred at no extra
instance cost. This is the right answer for a cluster that is not a reference
platform. Rejected on two grounds: the blocks have to be allocatable as
contiguous ranges, so it couples node startup to subnet layout and fails at
launch rather than at configuration; and lifting the ceiling also appears to
require the limit be set in node startup configuration and the node group
replaced, which puts a node replacement on the path of every capacity change.
Recorded as the production answer and deferred.

**Rejected: fewer replicas.** Would fit, and would make the horizontally
scaling service a single instance, which removes the only thing that makes it
the horizontally scaling service.

**Accepted cost.** Running cost rises from about $0.22 to about $0.26 an hour,
roughly nineteen percent, for capacity that is mostly idle on the day it is
bought. The nodes are also replaced to apply it, so this is the first change in
this platform's life that disrupts a running cluster rather than adding to it.

A second cost, stated because it would be easy to pretend otherwise: memory
rises too, and memory is expected to become the binding constraint once
something scrapes metrics. That is convenient and it is **not** the
justification. If the pod ceiling were not already reached, this change would
be premature and the honest thing would be to wait.

Measured after the change rather than predicted: allocatable memory per node
went from 1.40 Gi to 3.22 Gi, a factor of 2.3 rather than the 2 the instance
sizes imply. The difference is the amount each node reserves for itself, which
is close to fixed and therefore a smaller fraction of a larger node. Small
nodes lose proportionally more to overhead than their size suggests, which is
an argument against solving capacity with more small nodes that is separate
from the pod-slot arithmetic above.

---

## The pipeline's own commit must not start the pipeline

**Context.** The build pipeline commits an image reference back to the
repository it watches. A pipeline that commits to its own trigger can start
itself, and a loop that costs money per iteration is a poor thing to discover
by accident.

**Decision.** Nothing is built. The automatically provided token already has
this property: a push made with it does not create a new run. This was checked
against the platform's documentation rather than assumed, and the documented
exceptions are only the two manual trigger events, neither of which is used
here.

**Why it is worth an entry at all, given nothing was built.** Because the
alternatives people reach for are all worse, and reaching for one of them would
look like diligence. A commit-message convention that later gets edited; a path
filter that silently stops matching when a file moves; or a personal access
token — which would *reintroduce* the recursion the default token prevents,
while also putting a long-lived credential in a repository whose premise is not
holding those. Knowing the default is safe is what makes it possible to decline
all three.

**Decision, second half: which file the reference is written to.** The
development environment's values file, and only that one. Promotion to the next
environment is a human editing a file.

**Why.** Promotion is a decision. If the pipeline wrote to every environment,
every environment would receive every build, and the thing this platform exists
to demonstrate — that a release is a deliberate, visible, reversible act —
would be gone. A human editing one line is the smallest honest form of that.

**Accepted cost.** Promotion is manual, so it can be forgotten, and the two
environments will drift apart whenever someone does not get round to it. That
drift is the intended shape rather than a defect, but it does mean the
environments are not automatically comparable, and anyone reading one and
assuming the other matches will be wrong.

---

## An image is identified by content, not by a name that can be repointed

**Context.** A chart conventionally takes a repository and a tag and joins them
with a colon. A tag can be moved to different content later, which means the
cluster's contents would not be determined by what is committed.

**Decision.** The values file carries the repository and a content digest, the
template joins them with `@`, and there is no tag field at all.

**Why the tag field is removed rather than left empty.** A reference can be
built from a tag or from a digest and they use different separators, so a digest
cannot simply be put in a tag field. Leaving the field present invites someone
to set it, and a reference with both is either ambiguous or silently ignores
one. Removing it makes the wrong thing impossible rather than merely
discouraged.

**Rejected: a tag per build, immutable by convention.** Registries can be
configured to refuse overwriting a tag, which gets most of the benefit and
stays readable. Rejected because it is a property of the registry's
configuration rather than of the reference itself — the same committed string
means something different depending on a setting held somewhere else, and that
is precisely the kind of invisible dependency this platform spends its length
removing.

**Accepted cost.** A digest is unreadable. Nobody looking at an environment
values file can tell which version is deployed, and a diff between two releases
shows two meaningless strings. The pipeline writes a human-readable comment
beside it, which helps and is not load-bearing — being a comment, it will
eventually be wrong, and a comment that disagrees with the value beside it is
worse than no comment.

---

## The image is published so that pulling it needs no credential

**Context.** The cluster has to pull the images it runs. If the published
package requires authentication, the cluster needs a pull credential, which is
a secret.

**Decision.** The package is published readable without authentication, and the
cluster is given no pull credential.

**Why, and the reason is a loop rather than convenience.** The mechanism for
getting secrets into this cluster is an operator that runs as a container, so it
has to be pulled before it can supply anything. A cluster that cannot pull
without a secret cannot start the thing that provides the secret. It would work
today, because that operator comes from a registry that needs no credential —
but it is a dependency loop waiting for somebody to move an image, and the
failure would present as a cluster that cannot start rather than as a missing
credential.

The source repository is public, so there is nothing disclosed by the package
being public that is not already disclosed.

**Rejected: a private package with a pull credential supplied by the secrets
mechanism.** Closer to what a real company would do, and it would exercise the
secrets mechanism a third time. Rejected for the loop above, and because the
exercise would be circular: using the secrets mechanism to fetch the credential
needed to start the secrets mechanism.

**Accepted cost.** Anybody can pull these images and read what is in them.
These are deliberately trivial stubs that compute nothing, so there is nothing
inside to protect — but that is a property of this phase rather than a general
one, and the first image here with anything real in it would make this the
wrong choice. Worth re-deciding rather than inheriting.

Package visibility on this registry is also a property of the package and not
inherited from the repository, and new packages default to private. So this is
a setting that has to be applied deliberately and then confirmed by pulling
without credentials, not assumed from the repository being public.

---

## The batch worker's non-overlap is one line of configuration, not a lock

**Context.** The batch worker must never have two copies running at once. In
the scenario this platform is built around, two runs over the same batch pay a
merchant twice. That is not a performance concern to tune; it is the failure
the delivery design exists to prevent.

**Decision.** `concurrencyPolicy: Forbid` on the scheduled job. Nothing else.
No lock, no leader election, no sentinel, no check at startup.

**Why this is worth recording at all, being one line.** Because the obvious
instinct is to write something. A distributed lock is the kind of code that
looks like diligence and reads like competence, and it would be strictly worse
than the setting it replaced. A lock has to handle the holder dying mid-run —
the process killed, the node lost, the container evicted — and getting that
wrong produces either a job that can never run again because a stale lock is
held forever, or one that overlaps anyway because the lock expired early. The
scheduler already handles all of it, because it is tracking the job rather than
guessing from a flag.

This is the clearest instance in this repository of the distinction the whole
project rests on. The value added here is not code. It is knowing which of
three settings is correct and why, and being able to say what the other two
would cost.

**Rejected: `Allow`.** The default, and the hazard expressed as a setting. Two
runs proceed side by side.

**Rejected: `Replace`.** Kills the running job and starts the new one. Sounds
decisive and is worse than overlap here: a settlement run killed part-way
leaves work half-done, and a platform that cannot say which items were handled
is in a worse position than one that simply ran late.

**Related settings, chosen for the same reason.** Retries are off, because a
retry is a second attempt over the same batch. Late runs are not fired after
their window, because a settlement run belongs to a window and yesterday's job
executed this morning is a different job.

**Accepted cost, corrected after measuring it.** The original version of this
entry said a refused run is simply skipped, with no queue and no catch-up. That
was wrong, and the correction matters more than the original claim.

What actually happens was established by making a run outlast its own schedule
and watching: the refused run was **not** discarded. It started 103 seconds
late, the instant the previous run finished, because that was still inside the
window set by how late a run may begin. Nothing was lost. The refusal is
visible in the scheduler's own event — *not starting job because prior
execution is running* — and the run then arrives behind schedule.

So the guarantee is narrower than "one run per period". It is "never two at
once". A long run delays the next one rather than cancelling it, and whether a
sufficiently delayed run is eventually dropped is decided by a separate setting
that is easy to leave at whatever it was.

The real cost is therefore drift rather than loss. A worker that consistently
overruns pushes every subsequent run later until one of them finally exceeds
the lateness allowance and is dropped — at which point a run genuinely does
disappear, with nothing recording it beyond the absence. For a job whose output
belongs to a window, arriving late can matter as much as not arriving, and
neither condition is currently alarmed on.

A second cost, separate and real: a run that fails is terminal, so it does not
hold the slot. Only a run still *going* blocks the next one. That is the right
behaviour, and it means "the worker is wedged" and "the worker is failing every
time" produce completely different schedules, which anything watching this will
have to tell apart.

---

## The image scan fails the build only on findings somebody can act on

**Context.** The pipeline scans every image before publishing it. What it does
when the scan finds something is a decision with a cost in both directions, and
the default answers are both wrong.

**Decision.** Fail the build on high and critical findings **that have a fix
available**. Report and continue on everything else.

**Why the qualifier is the whole decision.** A gate that fails on findings with
no available fix cannot be satisfied by the person it blocks. There is nothing
to upgrade and nothing to patch, so the only ways past it are to disable the
gate, add an exception, or stop looking — and all three happen within about a
week of the first unfixable finding. A gate that is routinely bypassed is worse
than no gate, because the bypass becomes habit and then applies to the findings
that did matter.

Failing on fixable findings leaves an action attached to the failure: change a
version, rebuild, move on.

**Why the scan runs before publishing, not after.** The image is built and
loaded locally, scanned, and only then pushed. Scanning after publishing means
the thing being judged is already available to pull, and the gate is reduced to
a notification.

**Rejected: report everything, fail on nothing.** Honest about the limits of
scanning and popular for that reason. Rejected because a report nobody is
obliged to read is indistinguishable from not scanning, and this platform
already has one component whose failure is silent.

**Rejected: fail on everything, including unfixable findings.** Looks the most
rigorous and is the most likely to be switched off.

**Accepted cost, and it is a real one.** A vulnerability disclosed in a
dependency breaks this pipeline for changes that have nothing to do with it.
Someone pushing a one-line edit discovers that they now own a dependency
upgrade. That is a genuine tax on unrelated work, and the alternative is
shipping a known-fixable vulnerability because fixing it was inconvenient at
the time.

A second cost, quieter: the base image here is distroless and carries almost no
operating system packages, so this gate currently has very little to find. It
will look like it is working when it is mostly not being exercised, and the
first time it fires will be the first time it is really tested.

---

## The batch worker gets no database, because it has nothing to store

**Context.** A settlement worker that persists nothing is not the shape of a
settlement worker. The question was whether to give it a database, and if so
what happens to the contents when the platform is torn down between working
sessions.

**Decision.** No database. The worker stores nothing.

**Why, and it was not the money.** The smallest usable instance costs about two
cents an hour against a platform already running at thirty-five. Cost was never
going to decide this.

What decided it was insisting on the order: establish what the worker stores,
and only then decide where it lives. The first half has no answer. By the end
of the work the worker had demonstrated everything it exists to demonstrate — a
scheduled shape, refusal to run twice at once, a run deferred because the
previous one overran, a failure that is deliberately not retried — with a
process that sleeps and exits. Nothing was ever written down because there was
never anything to write.

Choosing storage first and then looking for something to put in it is how a
reference platform acquires a database it does not need, and then a backup
strategy for data nobody reads.

**Rejected: a row per processed item, to make overlap visible.** The strongest
argument, and it nearly carried. Two runs over one batch leaving two rows is a
more convincing demonstration than a scheduler event announcing that it
declined to start something.

It fails on what it would actually show. To see duplicate rows you must first
defeat the exclusion on purpose, and what you have then demonstrated is that a
row got written twice. The hazard this platform is built around is not a
duplicate row — it is a duplicate *payment*. Nothing here computes a payment
and nothing ever will. So the database would be demonstrating its own mechanism
while appearing to demonstrate the scenario, and a careful reader notices the
difference.

**Rejected: a database so the secrets mechanism has a second job.** A fair
point — a database password is a better test of that mechanism than a console
password. Rejected because building a stateful dependency in order to have a
credential worth fetching is inventing a requirement to justify a mechanism.

**Accepted cost, and it is the one a reviewer would raise.** The double-payment
hazard remains an assertion. The scenario document states that two concurrent
settlement runs would pay a merchant twice; nothing in this repository
demonstrates it, and now nothing will. What is demonstrated is that two runs
cannot occur — the prevention, never the harm.

The honest framing is that the harm could not have been demonstrated here under
any version of this decision, because demonstrating it requires the payment
logic the project refuses to write. Someone who asks to see the double payment
gets the scenario and a straight answer rather than a staged one.

A second cost: a settlement worker that settles nothing and stores nothing is a
shape without substance. Anyone opening its source finds a process that sleeps.
The file says so in its opening paragraph rather than letting them discover it.

A third, deferred rather than avoided: the question of what happens to stored
state on teardown is still real and still owed. It moves to the component that
introduces storage for a reason — the metrics database in the next stage, whose
contents are the record of how these services behaved. Asking it there means
asking it about state with a purpose instead of state invented to carry the
question.

## The controller's chart is fetched from a registry, not from a catalogue

Installing the delivery controller means fetching its chart, and a chart can be
fetched two ways. An HTTP chart repository publishes `index.yaml`, a catalogue
of every version of every chart the project ships; the client downloads the
whole catalogue and searches it for the one entry it wants. An OCI registry is
addressed per chart per version, so the request names the thing it wants and
gets only that.

For most projects the difference is invisible, and it was invisible here for
three phases. The catalogue is 1.68 megabytes against a chart of 236 kilobytes,
so seven eighths of every fetch was catalogue — but while the connection held
up, seven eighths of a fast transfer is still a fast transfer.

What exposed it was not a change in this repository. Nothing here that resolves
a chart had been touched in three weeks. It was the connection getting
unreliable, and measuring it is what made the decision obvious rather than
reactive. Five fetches of the catalogue: two never finished, timing out at 90
and 180 seconds, and the three that did took 15, 32 and 45 seconds. Throughput
ranged from 8 to 110 kilobytes a second. Three fetches of the same chart over
OCI took 4, 10 and 10 seconds.

That is the real shape of the problem. The catalogue was never reliably fast;
it was fast often enough that three phases of bringing this platform up and
down never landed on the bad end of the distribution. Twice in two days it
landed there, once installing and once destroying. The transfer sits on the
wrong side of the provider's timeout often enough to be a defect, and it was
always going to.

The failure appeared first on the way down and then on the way up, which is
what made it worth a decision rather than a retry. The same resolution happens
during `destroy`, and a destroy that cannot resolve a chart stops partway with
the cluster still running and still billing. A fetch that can fail open is an
annoyance during install and a cost leak during teardown.

**Rejected: raise the provider timeout.** The obvious move, and it does not
work. At the observed rate the catalogue needs four minutes on a good day and
the rate is not stable, so the timeout becomes a number that is either too
small to help or too large to fail usefully. It also treats a slow transfer as
the problem, when the problem is transferring a catalogue at all.

**Rejected: suppress the refresh on destroy and leave install alone.** This was
in fact the first fix, and it is why the second failure was a surprise rather
than a repeat. It worked, narrowly: `destroy` no longer re-resolved the chart.
But it fixed one direction of a problem that had two, and it bought that by
planning a destroy from unrefreshed state, which is a real cost paid for a
partial repair.

**Rejected: vendor the chart into the repository.** Removes the network from
the path entirely, and genuinely tempting. Rejected because the pinned version
is the interface here — upgrading the controller is meant to be an edit to one
variable, reviewable as one line. A vendored chart makes an upgrade a few
thousand lines of imported YAML, and the thing that is supposed to be easy to
audit becomes the thing nobody reads.

**Accepted cost.** The install now depends on a container registry rather than
a static web host, and registries require a token even for anonymous pulls.
That added a failure mode immediately: a stale credential for the same registry
sitting in the local Docker configuration caused the pull to be refused with
`403 denied`, where no credential at all succeeds. The catalogue it replaced had
no auth step and so could not fail that way. It then did exactly that a second
time, on a bring-up, which is what settled how it had to be handled: the
lifecycle scripts now point Terraform at an empty credential store belonging to
the repository rather than to the machine. Telling the operator to stay logged
out was not a fix, because the operator legitimately pushes images to that same
registry and the credential returns. The trade is a slow dependency
that failed often for a fast one that fails differently, and the new failure is
confusing the first time because being logged in is what breaks it.

A second cost: the two fetch methods are not guaranteed to serve byte-identical
charts forever, and nothing here verifies that they do. The version is pinned
and the registry reports a digest, but this project does not record that digest
or check it, so the pin is trusted rather than enforced.

## The metrics stack is one chart, with most of it switched off

The collector, the operator that drives it, two exporters and the place you
look at the result can be installed as one chart or as four. One chart was
chosen, and then roughly a third of it was disabled, which looks contradictory
enough to be worth setting out.

The four components have to agree with each other. The collector has to know
how to discover what the exporters expose; the views have to match the metric
names the exporters emit. Assembling them by hand means owning that
integration, and owning it on every upgrade, across four version numbers that
move independently. The combined chart owns it instead. This platform's whole
argument is that it supplies judgement rather than plumbing, and hand-wiring
four components that ship pre-wired is plumbing.

**Rejected: assembling from the separate charts.** Finer control over each
piece and only what is wanted gets installed. Rejected because the control is
over things this platform has no opinion about, while the cost — four pairs of
versions to keep compatible — is paid at every upgrade by whoever is holding it
then.

**What is switched off, which is the part that carries the judgement.**

Alert routing, because nothing here pages anybody yet. A notification component
with no destination configured is worse than an absent one: it looks installed,
it reports healthy, and it delivers nothing. It is also the difference between
six pods and seven on a cluster with ten free slots.

The scrape jobs for the control plane — scheduler, controller manager, etcd,
proxy. These are on by default because most clusters expose those components.
A managed cluster does not, so left on they produce targets that can never come
up. That is the failure worth naming: a permanently failing target teaches you
to read "down" as normal, and the one real failure then looks exactly like the
four decorative ones.

The bundled views, nearly all of them. They describe node pressure, control
plane latency and resource quotas — genuinely useful, and none of them answers
whether these two services are healthy, which is the only question this part of
the platform exists to answer.

**Accepted cost.** One version number now covers six components, so a problem
in any one of them blocks an upgrade of the other five. That is a real loss of
the control the rejected option would have given, and it will be felt on the
first upgrade that matters rather than today.

The second cost is less obvious and more likely to bite. What is installed no
longer matches the chart's own documentation. Anyone reading upstream will find
alerting, control plane dashboards and a set of views that are simply not here,
and the only record of why is the values block and this entry. A reader who
finds neither will reasonably conclude the installation is broken.

## What says the request-serving API is healthy, and what it cannot say

Three numbers, and they are the ordinary ones, because this service is the
ordinary shape: a process that accepts requests and answers them. How many
requests arrive, how many of them failed, and how long they took. The service
exposes exactly these already — a request counter labelled by path and status,
and a duration histogram labelled by path — so nothing had to be added to it to
make this answerable.

Each of the three, and the failure each one is blind to.

**Requests, counted by status.** The rate of requests whose status indicates
failure, against the rate overall. This is the closest thing to a direct answer:
if failures are climbing while the total is flat, something broke and callers
are seeing it. What it misses is a request that succeeds and is wrong — a
response with a status indicating success carrying the wrong amount. Nothing
here can see that, and nothing in this platform ever will, because the service
is a stub with no amounts in it.

**Request duration.** A distribution rather than an average, so that a minority
of slow responses is visible instead of being flattened by a majority of fast
ones. What it misses is the request that never finishes at all. A response that
hangs until the caller gives up is never recorded as a duration, so the number
can improve at the exact moment the service becomes unusable — the slow
requests leave the sample by failing to complete.

**Build info.** On its own this says nothing about health; it is always one.
It matters because its label carries the version, and the next stage runs two
versions at once on purpose. Without it, the three numbers above describe a
service rather than a version of one, and "the new version is failing" is not a
sentence the data can form. What it misses is everything else: it is an
attribution key, not an indicator.

**The uncomfortable part, which is the reason this entry exists.**

All three read zero when nobody is calling the service. No requests, no
failures, no durations. A service that is perfectly healthy and idle produces
the same numbers as a service that is unreachable, crash-looping, or gone — and
on a platform with no real users, idle is the normal state.

**Corrected after breaking it on purpose: they did not read zero, and that was
worse.** The counter records every request the process serves, and the cluster
probes it constantly for liveness and readiness. So an idle service reported a
steady rate of successful requests that was entirely the kubelet talking to
itself, and the view showed a service busily serving nobody. Worse still, when
the readiness probe was made to fail, those failures landed in the same counter
and the view reported a fifth of requests failing — which reads as users being
served errors, when no user was involved and the previous version was serving
every real request without fault.

The indicators now exclude the probe paths, which restores the zero-means-two-
things problem described above rather than removing it. That is the right
trade: a number that is honestly ambiguous is easier to reason about than one
that is confidently wrong. None of this was visible by reading the metric
definitions; it took throwing the switch.

So the numbers above are not sufficient on their own and are not treated as
such. Whether the service is *there* is a separate question from whether it is
*succeeding*, answered by whether its pods report ready, which the cluster
reports and the collector already gathers. The two have to be read together.
Ready with no traffic is idle. Not ready is broken. Traffic with failures is
broken differently. Any view that shows only the three numbers lets the second
of those masquerade as the first.

**Deliberately absent: any threshold.** No number here is declared too high.
What counts as too many failures, or too slow, is a release decision, and
choosing it now would mean choosing it before anything exists that has to act
on it. The predictable way that goes wrong is that the number gets picked to
make a release pass rather than to describe the service.

**Rejected: adding a metric that is non-zero while idle.** A heartbeat counter
would remove the zero-means-two-things problem at the source, and it was
tempting for exactly that reason. Rejected because the service is a stub whose
metrics were chosen when it was written, and changing it to make a view easier
to read is adding logic to a service to serve a dashboard. If a metric is only
needed because the collection is awkward, the collection is what is wrong.

**Accepted cost.** Answering "is it healthy" for this service takes two sources
rather than one — its own metrics plus the cluster's view of its pods — and
anybody reading only the first will misread an idle service as a working one
and a dead one as idle. That ambiguity is not solved here. It is marked, and
the view is built so the readiness signal sits beside the other three rather
than on a separate page.

## What says the batch worker is healthy, and why it is answered from outside

The other service is asked whether it is healthy by reading its own metrics.
This one mostly cannot be, and finding that out changed where the answer comes
from.

The familiar four signals do not transfer, and saying which do not is most of
the work. There is no traffic: nothing calls this service, and "how many runs"
is decided by the schedule rather than by demand, so it reports back only what
the schedule already states. There is no latency: latency is time spent while
something waits for an answer, and nothing waits on this. Errors transfer
directly — a run completed or it did not. Saturation transfers, but not through
capacity: there is no worker count to raise, because a second concurrent run is
the hazard this service is shaped to prevent rather than the cure for a slow
one. For a scheduled job, saturation is lateness. A run that outlasts the gap
to the next one pushes that next one later, and runs begin drifting.

**Why the numbers come from the cluster rather than from the process.** The
service exposes a run-outcome counter and a run-duration gauge, and both are
written at the moment the run ends. The process then exits and its metrics
endpoint goes with it. Scraping the real image mid-run returns neither: the
outcome counter has no series yet, because a labelled counter has none until
its label is first used, and the duration still reads zero. A collector that
asks on a timer therefore has almost no opportunity to read either one.

The durable record of a run is the Job object, which outlives the pod that did
the work, and the cluster's own exporter already reports on those. So the
primary indicators are read from there and the service's own metrics are the
supplement. That is the exact inverse of the request-serving service, and the
inversion is not a preference — it is what the difference between a process
that stays still and one that does not actually implies.

**The indicators.** Whether recent runs completed or failed. How long it has
been since one last succeeded. How long a run takes compared with the gap
before the next is due. And how many runs are active at once, which should
never exceed one.

The second of those is the one that would be missed by anybody porting the
API's thinking across. Counters move when something happens, and nothing moves
when nothing happens — so a worker that silently stops being scheduled produces
no failures, no errors, and no change in any total. The numbers simply stop,
and a stopped number is indistinguishable from a quiet one. Measuring elapsed
time since the last success is the only indicator here that treats absence as a
signal, and absence is this workload's most likely silent failure.

The fourth exists for a different reason again. It is not expected to vary. It
is there because it is the only number that would reveal the central hazard if
the scheduler's refusal to overlap ever stopped holding, and a guarantee that
nobody measures is a belief.

**Rejected: items processed, as a health indicator.** The most readily
available number and the least informative. It is the one value that *can* be
scraped mid-run, which makes it tempting. Rejected because its final figure —
the only one that says what the run actually got through — is never collected,
and in a stub it counts loop iterations over nothing.

**Rejected: adding a push step so the service reports its own outcome.** This
would make the service's own numbers reachable and is a known, standard
remedy. Rejected at this stage because the cluster already holds the same facts
in the Job objects, and installing a component to re-learn something already
recorded is work added on top of plumbing that exists.

**No threshold appears here.** How late is too late, and how long is too long,
are release decisions and belong to whatever has to act on them.

**Accepted cost.** The chosen indicators say whether runs happen and whether
they finish, and nothing about whether they are right. A run that completes
promptly having settled the wrong things reports as healthy on every one of
them. That gap is permanent rather than deferred, because the service has no
settlement logic to be right or wrong about and is not going to grow any.

A second cost: two of the four are read from the cluster's record rather than
from the service, so they describe what the scheduler observed rather than what
the code did. If a run exits zero while having done nothing at all, the record
says it succeeded, and nothing here contradicts it.

## The batch worker gets no push intermediary, because the cluster already knows

A process that runs for half a minute and exits is the classic awkward case for
a collector that asks on a timer. The standard remedy is well known: the job
pushes its numbers to a component that stays running, and the collector reads
that component instead. The question was whether this platform needs one.

**What was actually observed.** The worker was given a scrape definition of its
own and the collector was left to do its best, with a deliberately short
interval to give it the best chance. It did catch runs. Of the four numbers the
service exposes, three were present afterwards:

```
settlement_worker_build_info               1
settlement_worker_items_processed_total    25
settlement_worker_run_duration_seconds     0
settlement_worker_runs_total               ABSENT
```

That is the worst possible result, and it is worse than collecting nothing.
Three series exist, so the collection looks like it is working. But the two
numbers that say whether the run was any good are the two that are useless: the
outcome counter is absent entirely, because a labelled counter has no series
until its label is first used and the outcome is only set as the run ends; and
the duration reads zero, because it too is set at the end. Both are written in
the last instant before the process exits and takes its endpoint with it.

A partial reading that looks complete is the failure mode worth naming here.
Nothing about that output announces itself as broken.

**Why no intermediary was added anyway.** Because the facts are already
recorded somewhere that does not disappear. A run leaves a Job object behind,
and the chart keeps several of them on purpose; the cluster's own exporter
reports on those, and was already installed. Asked for the same facts from that
source, in the same cluster, at the same moment:

```
active runs                      0
succeeded / failed jobs          2 / 0
seconds since the last success   21
last run duration                34
```

The duration is the one to look at twice. The pod's own gauge said zero. The
cluster's record said thirty-four seconds, which is the truth. The information
was never missing — it was being asked of the wrong thing.

**Rejected: adding the push intermediary.** It is the textbook answer, it
would work, and it would make the service's own numbers reachable, including
the one distinction the cluster's record cannot make — a run that was
interrupted part-way versus one that failed outright. Rejected because it
would be a component installed, and a pod spent, to re-learn facts the platform
already has. This repository's whole argument is that it supplies judgement
rather than machinery, and installing machinery to duplicate an existing record
is the clearest way to contradict that.

**Accepted cost.** Interrupted and failed become the same thing. The service
distinguishes them and the cluster does not, so a run stopped part-way through
by a shutdown signal is recorded exactly like one that exited with an error.
That distinction was deliberately built into the service and is now not
observable, which is a real loss rather than a tidy one.

A second cost: the indicators now describe what the scheduler saw, not what the
code did. A run that exits zero having processed nothing is recorded as a
success, and nothing here would contradict it.

A third, smaller: the worker keeps a scrape definition that produces three
series of limited use. It is kept rather than deleted because the partial
reading is itself the evidence for this decision, and because the one thing it
does supply — which version performed a run — is needed by the stage that
releases two versions at once.

## The measurements are disposable, and the platform already treated them that way

The question of what happens to stored data when this platform is parked has
been outstanding since the first phase. It was deferred twice, deliberately,
because until something held state worth keeping there was nothing to decide
about. The metrics database is that something, so it is decided here.

**The decision: the data is disposable. It is not snapshotted, not excluded
from teardown, and not restored. Retention is twenty-four hours.**

**What was found rather than assumed.** The intention had been to choose
between three options — snapshot and restore, exclude the storage from
teardown, or declare the data disposable. Inspecting the running cluster
removed most of that choice:

```
volumeClaimTemplates   none
PVCs cluster-wide      none
the database volume    an empty directory belonging to the pod
```

There is no persistent storage anywhere in this platform. The collector's
database lives in a directory that is created with its pod and deleted with
it. So the premise behind the question was wrong in the platform's favour: the
worry was that a teardown would destroy the history, when in fact a routine
reschedule destroys it first, and has been doing so all along.

That also exposed a number that was describing nothing. The chart's default
retention is ten days. Ten days of retention over storage that cannot survive
a pod moving between nodes is not a short history, it is a false one. It is
now twenty-four hours, which is roughly the longest window this platform ever
actually has, because the cluster itself is parked between sessions and no
measurement can outlive the cluster that recorded it.

**Rejected: snapshot the database and restore it on the way back up.** This is
the option that sounds most responsible, and it is the one worth arguing
against properly. A metrics history is exactly what you want across a release
— the whole point of the next phase is comparing a new version against the
behaviour of the old one, and that comparison is easier with yesterday's
numbers than without them. Rejected because the comparison the next phase needs
happens *within* a single release, over minutes, between two versions running
at the same time. It never reaches back across a teardown. Building a snapshot
and restore path would be machinery serving a need that has not been
demonstrated, on a platform whose argument is that it installs less.

**Rejected: exclude the storage from teardown so it survives.** Rejected on the
platform's defining property. Everything here is rebuilt from what is committed,
and a volume that outlives the cluster is the one object that could not be. It
would also keep billing while the rest of the platform is parked precisely to
stop it billing, which inverts the reason for tearing down at all.

**Accepted cost, and it is a real one.** Every measurement in this document was
taken from a cluster that no longer exists by the time anybody reads it. The
numbers recorded while breaking both services on purpose — the probe traffic
that was being counted as user traffic, the readiness failure that kept serving
while the deploy wedged, the liveness failure that did not — are preserved only
as text written down at the time. Nobody can re-run those queries. If a figure
here is wrong, the evidence that would correct it is gone, and the only remedy
is to rebuild the platform and break it again.

A second cost: twenty-four hours is shorter than the interval between working
sessions, so in practice the collector is almost always empty when work starts.
The first question of any session cannot be answered from history, only from
what happens next.

## The nodes stay as they are, and the next phase gets the measurement instead

The largest thing this platform installs was added in this phase, and the
obvious next move is to make the cluster bigger, because the phase after this
one brings a release controller and a second copy of a service. That move is
declined.

**What the cluster actually holds, counted rather than projected:**

```
kube-system       8        ceiling            34
argocd            7        in use             28
metrics           6        free                6
external-secrets  3
dev               2        memory requested   16% and 21% per node
traefik           1        memory limits      46% and 47% per node
staging           1        cpu limits         72% and 56% per node
```

Six slots free, against four predicted during design. The gap is worth keeping
because it is a lesson about this platform's own shape rather than an
arithmetic slip: the estimate counted the batch worker's pods as though they
were always present. They are not. The worker exists for about thirty seconds
in every ten minutes, so for most of any hour it occupies nothing at all, and
a static count of the workloads overstates what it costs. At the moment a run
is in flight in both environments the free figure is four, not six, and that
peak is the number worth planning against.

Memory was expected to be the binding constraint and is not: a fifth of each
node is requested and under half is committed as limits. Processor limits are
the tighter figure at seventy-two percent on one node, which is still not
binding, but it is the number to watch next rather than memory.

**Rejected: resizing now, because the next phase will need it.** The case is
real. The next phase adds a release controller and runs a second copy of a
service while traffic is being shifted, which is plausibly three or four pods
against a peak headroom of four. Resizing now would avoid opening that phase
with a disruptive change to a running cluster.

It is declined because sizing against something that does not exist yet is
guessing, and the guess is usually wrong in the expensive direction. The
previous phase got this right by resizing against what it was actually adding
and measuring the result, and this phase has just produced two reminders of why
measurement beats projection: the pod estimate was out by two, and a figure
written in this repository about pods consuming quota after they finish turned
out, when checked, to be false.

**Accepted cost.** The next phase probably opens with a node replacement, and
replacing nodes under a running cluster is disruptive in a way that doing it
now would not be. That cost is being moved rather than avoided, and moving it
is only worth it because it buys a measurement in place of an estimate.

A second cost, and the sharper one: peak headroom is four slots, which is at
the lower end of what the next phase is likely to need. If it needs five, the
discovery happens in the middle of that phase rather than at the start of this
one, with a cluster already running the thing that needs the room.

---

## A third node, bought against a measured peak rather than a projected one

**Context.** The previous phase closed by warning that peak headroom was four
slots and that five would be discovered mid-phase. It was.

The numbers, read from a running cluster rather than recalled. Each node of the
current size has a hard ceiling of seventeen pods, so the pair offers
thirty-four. Twenty-eight are occupied with nothing scheduled running. A batch
run in one environment makes twenty-nine, measured by catching one in flight.
The scheduled jobs in the two environments coincide at the top of every hour,
and each contributes a single pod, so the fullest the cluster ever gets today
is thirty — four free.

Progressive delivery adds three things to that. A release controller, which its
chart renders as two replicas. A source of traffic, because an error rate
computed over no requests is not a measurement. And a second copy of the
service while traffic is being shifted to it, which on two replicas is one more
pod. Against four free slots that is thirty-four of thirty-four: exactly full,
with no room for anything to be rescheduled.

**Decision.** The controller runs a single replica, and the node group grows
from two nodes to three of the same size.

**Why the controller is one replica.** Two is a high-availability default, and
high availability of the release controller is not a property this platform
demonstrates or needs. It is one cluster, torn down between sessions, and the
progress of a release is recorded in the rollout object rather than in the
controller's memory, so a controller that restarts mid-release resumes rather
than loses it. Running two would be paying for a property the platform does not
claim.

**Why a third node is still needed after that.** One replica brings the worst
moment to thirty-three of thirty-four. A single free slot is not headroom. It
is also not evenly distributed: the two nodes were carrying fifteen and
fourteen of seventeen when this was measured, so a slot free on paper may be
free on the wrong node.

**Rejected: two larger nodes instead of three of this size.** The previous
sizing decision chose exactly this, and rejected a third node on the grounds
that per usable slot it was the worse buy. That reasoning was correct then and
does not apply now. Then, both options were marginal — thirty-three slots
against thirty-four — so the only thing separating them was cost per slot.
Now the smaller option is comfortably sufficient and the larger one is roughly
double what is needed, so absolute cost decides instead. The larger pair also
replaces both nodes under a running cluster, where adding a node does not
disturb anything already placed.

**Rejected: changing nothing and accepting one free slot.** The demonstration
this phase exists to produce runs for several minutes, and the batch job in one
environment runs every five, so a release and a batch run will overlap rather
than might. A batch pod that cannot be placed does not fail loudly; it waits,
or its run is skipped, and the indicator the previous phase chose for exactly
that situation starts climbing in the middle of a release that is supposed to
be the thing under observation. Saving four cents an hour by corrupting the
measurement is the wrong trade.

**Rejected again: raising the per-node address limit instead of the node
count.** Still the right answer for a cluster that is not a reference platform,
still rejected for the reasons recorded when the nodes were last resized, and
still the production answer. Nothing has changed to make it cheaper.

**Accepted cost.** Running cost rises from about $0.235 to about $0.277 an
hour, roughly eighteen percent, for capacity that is occupied for about a
minute in every hour. The whole case for it rests on the worst moment rather
than the usual one.

The new node is also not worth seventeen slots. Each node arrives already owing
four pods to agents that run on every node — networking, service proxy,
identity, and the metrics exporter added last phase — so seventeen gross is
thirteen net. That figure is itself a correction: the last time this was
written down the per-node debt was three, and observability made it four
without the earlier entry being revisited. Per usable slot, this is knowingly
the worse purchase of the two on offer, bought because the cheaper total was
the one that mattered.

Measured after the change rather than predicted. Fifty-one slots, thirty-two
occupied at rest, nineteen free. The new node arrived owing exactly the four
per-node agents the estimate assumed, so the predicted fourteen free at the
worst moment stands. The three nodes carry fifteen, thirteen and five, because
nothing already placed moves to a node that appears later; the imbalance
resolves itself only as pods are replaced, which is worth knowing before
reading anything into it.

The two-step shape of the change was not predicted and is the part worth
keeping. Raising the count in configuration was refused outright: the module
stops managing the desired size once the group exists, on the assumption that
something inside the cluster scales it, and nothing here does. So the floor and
the ceiling are all that configuration still controls, and the cloud will not
accept a floor above a desired size it has been told to leave alone. Growing a
live node group therefore takes a change outside the configuration followed by
one inside it. Building the same cluster from nothing never meets this, which
is exactly why it was not noticed until a running cluster had to grow.

---

## Two settings the release controller does not copy from its neighbours

Both look like oversights against the applications sitting beside it in the
same directory, and both are deliberate. Recording them because the next
person to read that file will reach for consistency, which is usually the
right instinct and is wrong twice here.

**The chart is fetched from a catalogue, not a registry.** The opposite was
decided a phase ago, measured, and written down. It still holds where it was
taken and it does not reach here.

That decision was about the provisioning tool, running on an operator's
machine, fetching a chart over whatever connection that machine has. A 1.68
megabyte catalogue sat on the wrong side of a timeout, and the failure that
made it urgent was a teardown stopping half-finished with a cluster still
billing. None of those conditions describe this fetch. It is made by a
component inside the cluster on a datacentre connection, it is cached beyond
any single synchronisation, and a slow fetch delays a release rather than
stranding a teardown.

**Rejected: addressing it by registry anyway, for consistency.** Tempting,
and it would read better. Rejected on two grounds. The first is that the
registry path for this component is not documented as working without a stored
credential object for the version running here, and the number of objects that
exist outside the delivery controller's management is deliberately fixed at
three. The second is worse: copying a decision to a place where its reasoning
does not apply makes the original reasoning harder to trust, because a reader
who checks will find the measurement describes a situation that is not this
one.

**No server-side apply, where the two other type-bearing applications both use
it.** Their reason is size. A type definition can be large enough that
recording a copy of it in an annotation exceeds the 262144-byte ceiling on
that annotation, and server-side apply keeps no such copy.

The expectation was that five definitions of roughly a quarter of a megabyte
each would be the same case, and the setting was about to be carried across on
that basis. Measuring it first gave the opposite answer. The annotation holds
the object encoded compactly rather than as the indented text a human reads,
and the largest of these five is 69 kilobytes that way against 237 kilobytes on
disk. All five are comfortably clear of the ceiling.

**Accepted cost.** Two applications in one directory now do the same kind of
thing two different ways, and the file has to carry the reason in a comment or
the next change will quietly unify them. The cost of the second is narrower and
real: client-side apply does store a redundant copy of every one of these five
definitions, which is waste that server-side apply would avoid. It is accepted
because the setting exists here to prevent a failure, that failure was measured
not to apply, and switching it on for tidiness would mean the next person
cannot tell which of the three applications turned it on for a reason.

---

## Traffic is weighted through the portable routing API, by a plugin rather than natively

The controller that runs a release can shift traffic through several routing
layers. For the one installed here it has two routes, and they are not
equivalent.

The first is built in: the controller understands this router's own resource
type directly, needs nothing extra installed, and would almost certainly have
worked first time. The second expresses the same weighting in the
vendor-neutral routing API, and the controller cannot do that by itself — the
support lives in a separate executable it downloads at startup and runs as a
child process.

**Decision. The plugin, with the built-in support kept as the fallback.**

**Why.** The weighting is the single most copyable thing in this repository.
Somebody reading it to work out how to release safely is far more likely to be
running a different router than the same one, and a weighting expressed in one
router's private type teaches them nothing transferable. The portable API is
also where the ecosystem is going: the older object type this platform
deliberately does not install is the one being retired, and the newer one is
what replaced it.

**Rejected: the built-in support, for being simpler.** It is simpler, and that
is a real argument rather than a straw one. It was declined because the
simplicity is bought by writing the one transferable idea here in the least
transferable form.

**Rejected: downgrading the routing API's type definitions to match the
plugin's published compatibility table.** The plugin lists one version of this
router as tested, against type definitions one minor version older than the
ones running here, and does not list its own current release in that table at
all. Matching it would have meant regressing a working, already-installed
component to suit somebody else's test matrix. The types involved are stable
across minor versions, and establishing that the combination works here is the
answer to an untested pairing. Chasing a test matrix backwards is not.

**Accepted cost, four of them, and the first is the one that matters.**

The release path now depends on a combination nobody has published evidence
for. That was accepted on the condition that it was established first rather
than discovered later, and it was: the plugin loads and is addressed below.

The second is a new kind of dependency. Everything else this platform installs
is a chart, an image or a module, each pinned in a way the rest of the
repository already understands. This is a file fetched from a release host at
process start, so it is pinned by release tag and by checksum, and the
controller refuses to start if either is unsatisfied. It is also the only
dependency here that can go stale without anything failing.

The third was not anticipated and was found by reading the probe
configuration rather than by an outage. The controller downloads 77.7 MB
before it answers anything, every time its pod is replaced, and the chart kills
a container that has not answered within ninety seconds. A kill restarts the
download, so a fetch slower than the budget produces a restart loop rather than
a slow start. The start window was widened to cover it.

The number first used to justify that widening was wrong, and wrong in an
instructive way: fifty-one seconds, measured on the connection of the machine
this repository is edited from, which is not where the download happens. From
inside the cluster it took **677 milliseconds**. The window is kept, because
the risk it guards is a slow release host rather than a slow process, but it is
now sized against a stated risk instead of against a measurement of the wrong
thing.

What the wider window costs is that a controller which wedges inside its first
two and a half minutes is no longer caught by this probe. That is the narrower
risk of the two: the probe exists to catch a running controller that has
stopped answering, and start-up is the one period in which slow and stuck look
identical from outside.

The fourth is that the plugin inherits the controller's permissions and the
chart grants the routing API one verb less than the plugin's documentation
asks for. The verb was added rather than left to be discovered during a release
with traffic already split.

---

## How the service is published, and why it now has three addresses

Weighted releases need somewhere for the weight to be written and two things
to weight between. Both of those changed how this service is exposed.

**Routes attach to the shared gateway from any namespace that is an
environment.** The gateway's default is to accept routes only from its own
namespace, which would have meant every route living beside the router rather
than beside the service it routes to.

**Rejected: opening it to all namespaces.** One word shorter, and it would let
anything anywhere in the cluster publish itself through the front door,
including things that have no business being reachable. **Rejected: listing the
environment namespaces by name.** Correct today and wrong the first time a
third environment is added, in a file nobody would think to edit. The rule
instead matches the presence of the label that the environment chart puts on
every namespace it creates, so it reads "any namespace that is an environment"
and needs no edit to stay true.

**Requests are matched by host name, not by path.** Two environments share one
gateway, and something has to tell their routes apart.

**Rejected: a path prefix per environment.** It needs no host name at all,
which is genuinely simpler given that nothing here publishes a DNS record. It
was declined because it puts the environment into the request path, and the
request path is the label this service's own measurements are grouped by — so
every rate would have been split by environment inside a single environment's
view, and the thresholds chosen later would have been chosen against a
different shape of data than the one a real deployment produces.

**Accepted cost.** Nothing in this platform publishes a name that resolves to
the load balancer, so a request from outside has to carry the host name itself.
Every demonstration of a weight therefore involves a header that a real
deployment would not need. That is a gap in the demonstration rather than in
the design, and it is better than distorting the measurements.

**Three addresses where there was one.** One selects every version and exists
to be scraped; two are pinned by the controller to a single version each and
exist to be routed to. They cannot be the same object: the routed addresses
must resolve to one version at a time, and the scraped one must resolve to
both or half the traffic during a release is invisible.

**Rejected: scraping the pods directly and keeping one address.** It would have
removed the third service entirely and given the version label for free. It
was declined because the asymmetry between the two services in this platform
is the argument the repository exists to make, and how each one is found by the
collector is part of that asymmetry: the request-serving service is found
through an address because it has one, and the batch worker is found by label
because it never does.

**Accepted cost.** A service exists whose only consumer is the collector, which
looks redundant until you know why, and three objects now carry this service's
name label where one used to.

That last point cost something immediately. The scrape definition had always
selected on the name label, and with three services carrying it, every pod was
about to be scraped once per service. A request rate would have read three
times its true value at rest and somewhere between two and three times during
a release — moving in the right direction, which is the hardest kind of wrong
to notice. The selector is now matched on what an address selects rather than
what it is called.

---

## The requests a release is judged on are generated, and said to be

This platform has no users. Every request rate it has ever recorded was the
cluster probing itself, and those paths are now deliberately excluded from
what counts as traffic — which leaves zero.

A release that widens or withdraws itself based on the share of requests
failing needs requests to take a share of. A share of nothing is not a
measurement that happens to be zero; it is a division that returns whatever
the tooling decides to return when asked about nothing. So the requests are
generated.

**Decision.** A single sender, in one environment, issuing one request at a
time through the router's own address with the host name the route matches on.
It lives in its own chart named for what it is, is labelled as existing for a
demonstration, and is listed in the same directory as everything else rather
than tucked away.

**Why through the front door rather than at the service.** This is the part
that is easy to get wrong and impossible to notice afterwards. Requests sent
straight at the service produce a healthy-looking rate and bypass the traffic
split completely: the release could set any weight it liked and the load would
keep arriving at both versions in whatever proportion their endpoints happened
to be in. Every number would look reasonable and none of them would be about
the release.

**Rejected: a load testing tool.** There are good ones, and one would give
distributions, percentiles and a request rate that holds steady under
contention. It was declined because load testing and traffic generation are
different activities that look similar. The question here is "what share of
requests failed", not "what can this take", and installing a tool built for
the second invites tuning it until the first comes out favourable. A sender
that cannot be turned up is a sender nobody will be tempted to turn up.

**Rejected: generating the load from outside the cluster.** Closer to real,
and genuinely attractive: traffic from an operator's machine arrives the way a
user's would. Declined because it is not committed anywhere, so a release could
only be demonstrated while somebody happened to have a terminal open, and the
evidence would depend on a laptop staying awake.

**Rejected: adding an endpoint to the service to drive load internally.** It
would need no extra pod. It would also mean changing a service in order to
test the mechanism that releases it, and the services here stay stubs for the
same reason.

**Accepted cost, and it is the sharpest in this phase.** No real user traffic
has ever reached this platform, and after this change the graphs look as
though it has. Anybody reading a request rate here is reading a loop, and the
only defence against that being mistaken for a user is that it is said plainly
— in the component's name, in its labels, in its chart description, and here.
A graph is more persuasive than a caveat, which is why the caveat is in four
places.

It also costs a pod in an environment that did not have one spare, and the
ceiling on that environment was raised from six to eight to make room. The
count came out at exactly six at the fullest moment a release produces — two
copies on the trusted version, two on the version being tried, a batch run,
and the sender — and a ceiling that is exactly met rejects the next pod, which
would stall a release with traffic already split. Processor and memory were
never close: a quarter of the processor ceiling and a sixth of the memory one.

---

## What a release is judged on, and the thresholds in it

This is the deliverable of this phase. The controller, the router and the
weighting all existed before this repository; the numbers below are what it
supplies, and they are chosen against this service rather than against
whatever makes a release succeed.

### The finding the whole design turns on

**The service's own error counter cannot see either way this service can
fail.**

Both failure switches act on the health endpoints. The handler that serves
requests returns success unconditionally — measured across 8,421 requests,
every one of them successful, across every version ever run. So a candidate
that never becomes ready is never sent a request and reports **no failures at
all**. Its error rate is zero because it is dead.

To a query that sums failures, "answering everything correctly" and "not
answering" are the same answer. A gate built only on the share of requests
failing would therefore pass a version that is serving nothing, on a perfect
record.

This is the third time this platform has produced that shape. A sum over a
selector matching nothing returns no series rather than zero. A scheduled job
that silently stops being scheduled increments no failure counter. The pattern
is worth naming: **every measurement of failure needs a companion measurement
that the thing is running at all**, because absence and perfection are
indistinguishable to anything that counts.

### The schedule

Ten percent of traffic, then thirty, then sixty, holding three minutes at
each.

**Ten first, and the reason is the measurement rather than the exposure.** At
the measured traffic of 4.87 requests a second, ten percent gives the
candidate about half a request a second, or roughly 58 requests in a window.
That is the smallest sample in which a failure is distinguishable from
silence. At five percent the window holds 29 requests and a single failure is
3.4 percent of the sample, so the measurement becomes coarser than any
threshold worth setting — and a failing version is then **more** likely to
clear the first gate and be promoted to a weight where it does more harm.
Below a certain weight, a smaller first step makes a release less safe, which
is not obvious and is why this number is not simply as small as possible.

**Rejected: five percent for five minutes**, which is the example in most of
the documentation for this kind of tool. It is not wrong in general and it is
unjustifiable here, because at this service's traffic the first window would
not hold enough requests to read.

**Three minutes at each step** is six scrapes at the collector's thirty-second
interval. Two minutes gives four samples and one gives two, and a rate
computed from two samples is a difference rather than a rate. A longer pause
costs release time but not exposure to a bad version, because how quickly a
release is abandoned is set by the gate's own interval and tolerance rather
than by how long a passing step waits. That asymmetry is what makes the more
conservative number cheap.

### The gate

Three measurements every thirty seconds — one per scrape, because asking more
often than the data changes re-reads the same samples and makes one transient
look like several independent observations. Three failed measurements abandon
the release, so a candidate must look wrong for about ninety seconds.

**The candidate is serving at least 0.1 requests a second.** A fifth of what
the smallest step should produce. This exists because of the finding above,
and it is the only one of the three that catches the most likely failure.

**No more than one percent of its real requests failed.** Probe paths
excluded, both halves guarded against matching nothing, the denominator
clamped — the last two being the correction to a bug this repository shipped
twice, where a ratio read "no data" at exactly the moment the service was
healthiest.

**The precision of "one percent" is partly a fiction and saying so is the
point.** At 58 requests in a window, one failure is 1.7 percent; there is no
sample in which this gate can read one percent. It means, in practice, that
any failed request is a breach, and the tolerance for a transient lives in the
number of breaching measurements rather than in a looser percentage. A service
with real traffic would make this a genuine proportion and could afford a
smaller tolerance. Here the two numbers trade roles, and a reader who assumes
the threshold is doing the work would be reading it wrong.

**Its 95th percentile request duration stays under ten milliseconds.** This
one is nearly blind and is kept anyway. Every one of those 8,421 requests fell
in the histogram's smallest bucket, five milliseconds, and the true mean is
nine microseconds — so the reported percentile is interpolation inside a
bucket containing every observation, not a measurement. The gate can detect
only a regression large enough to cross five milliseconds, a factor of roughly
five hundred. It cannot see a service that becomes ten times slower.

**Rejected: removing it.** A candidate that is slow without failing is a real
way to be worse, and the other two measurements cannot see it at all.
**Rejected: a tighter value.** The idle reading is 4.75 milliseconds, so
anything lower sits a rounding error from its own threshold.

The limit is in the bucket boundaries chosen when the metric was added, not in
the threshold. Correcting it means re-bucketing the histogram, which means
changing a service, which is not this phase's business.

### Why the first measurement waits

The gate does not read anything for the first minute after traffic reaches the
candidate, and without that delay it fails healthy releases.

A rate computed over a two-minute window twenty seconds after traffic started
describes the window rather than the service. The arithmetic gives 0.061
requests a second against a floor of 0.1, so a perfectly good candidate is
marked absent and withdrawn. At sixty seconds the same query reads 0.243, two
and a half times the floor.

The other two measurements need the delay for a different and harder reason. A
quantile over a window containing no observations returns nothing at all, and
nothing is not a value that can be compared against a threshold — it is
reported as the query having failed rather than the candidate having failed,
which carries a different tolerance and would be misread as a measurement.

This is the same principle as the length of each step: a measurement is only
worth taking once there is enough in the window to measure. It was found by
arithmetic before the gate ever ran, which is the only reason it was not found
by a good release being withdrawn.

### Accepted cost

Every number here is calibrated against a traffic rate that is generated, not
earned. At 4.87 requests a second the sample in a window is small enough that
the error threshold cannot express itself honestly, and the compensation —
putting the tolerance into the count of bad measurements instead — is a
workaround for low volume rather than a principle. A reader taking these
numbers to a service with real traffic should move the tolerance down and the
threshold's precision up, and the reason this is stated rather than quietly
left is that the numbers would otherwise look transferable.

The second cost is slower releases. Nine minutes of weighting and waiting for
a change that a plain replacement would have applied in under a minute. That
is the price of finding out, and it is only worth paying for a service where
being wrong in front of users costs more than nine minutes does.

---

## What progressive delivery cost, measured during a release rather than at rest

### Pods

| moment | used | of | free |
|---|---|---|---|
| before the phase, at rest | 28 | 34 | 6 |
| before the phase, at its fullest | 30 | 34 | 4 |
| after a third node, at rest | 32 | 51 | 19 |
| **during a release, with batch runs overlapping** | **36** | **51** | **15** |

The phase added two standing pods — a release controller at one replica, and
one sender generating the requests a release is judged on — and one more
during a release.

**The canary costs one pod, not two.** At any weight below a hundred percent,
a service of two replicas rounds to a single candidate pod, so the second copy
the sizing was done against never appears. The phase was planned for a peak of
four free slots and ended with fifteen, which means the third node was bought
against a worst case that was one pod pessimistic.

That does not make the node wrong. Without it the measured peak of 36 would
have been 32 of 34, with two slots spare and a namespace quota that would have
rejected the next pod. But the margin is larger than intended and the reason
is worth recording rather than enjoying quietly: the estimate assumed the
canary scales with the weight, and it scales with the replica count.

### Money, and a correction

The running cost was projected at about $0.277 an hour when the third node was
bought. **Measured against a billed day, it is $0.34.**

Measured on **2026-11-13**, from one billed day. Superseded by a two-day
measurement on 2026-11-19 in [architecture.md](architecture.md), which puts the
figure between $0.35 and $0.42 depending on how long the session runs — the
reason being that address translation is billed per gigabyte and a rebuild
pulls every image through it, so a short session costs more per hour.

| | per hour |
|---|---|
| three nodes | 0.1144 |
| cluster control plane | 0.1000 |
| network address translation, storage, data | 0.0973 |
| load balancing | 0.0280 |
| **total while running** | **0.3397** |

The gap of six cents an hour is not the node. It is the two lines that were
never in any estimate here: data passing through the network address
translation gateway, and the load balancer. Every figure quoted in this
repository until now was built from instance and control-plane rates, which
are the prices that are easy to look up, and ignored the ones that are
metered by use.

This matters beyond the arithmetic. Address translation is charged per
gigabyte processed, so it rises with image pulls — which means a day of
rebuilding and redeploying costs more per hour than a day of running the same
thing, and the number moves with activity rather than with what is installed.
A reader sizing a cluster from the first three lines of that table would be
about twenty percent light.

Two charges continue with the cluster torn down: the stored secrets and their
key, about three cents a day together. Deliberate, and the only thing in this
platform that survives a teardown.

### Accepted cost

Eighteen percent more per hour for capacity that is mostly idle, bought
against a peak that lasts about a minute an hour. Stated honestly, the
measured increase is larger in absolute terms than the decision anticipated,
because the baseline it was compared against was itself understated.

### What the next phase should expect

The batch worker's release safety needs no second copy of anything — the
hazard it addresses is precisely that two copies must never run — so it should
cost less in pods than this phase did, not more. What it may need instead is
somewhere to record that a run is in flight, and whatever that turns out to be
is more likely to be a stored object than a pod.

Fifteen free slots during a release is room for that and for being wrong about
it once.

---

## The mechanism that holds releases during a batch run was not built, because it already exists

This phase was scoped to build one. The premise was measured before anything
was built against it, and the premise was false.

**What the plan assumed.** That a release landing while a settlement run is in
progress could put two versions on one batch, and that something had to hold
releases until runs finished.

**What is actually true.** A synchronisation three minutes twenty-five seconds
into a four-minute run did not touch the run. Same identifier throughout, same
image, finished normally on the old version. The schedule picked up the new
version for the next run.

The reason is ownership. The repository declares a schedule; the runs that
schedule creates belong to it and carry no tracking annotation from the
delivery controller at all. A synchronisation updates the template and has
nothing to say about a run already in progress.

**Decision. Build nothing. State the guarantee, attribute it honestly, and
demonstrate where it stops.**

**Rejected: synchronisation windows.** The original plan, and the obvious tool.
Periods during which the delivery controller will not apply changes, aligned
with the schedule so that releases avoid runs. Rejected because a release
during a run is not dangerous, so the windows would deny releases for a
quarter of every hour in exchange for nothing — and would have to be kept
aligned by hand with a schedule they cannot read. A guard whose only effect is
to delay safe things is not a safety feature.

**Rejected: a check that refuses to synchronise while a run is active.**
Technically possible as a pre-synchronisation step. Rejected on the same
ground, and on two of its own: a refused synchronisation is reported as a
failure rather than as a wait, so the operator sees an error where the truth is
"not yet"; and the check is itself a workload that has to be scheduled, which
spends the capacity the phase would be protecting.

**Rejected: building something anyway, to have built something.** The honest
version of the temptation. A phase that reports the platform already works
looks like a phase that did nothing, and there is real pressure to produce a
mechanism as evidence of attention. Declined, because the project's own rule
is that reimplementing what the platform provides is the failure mode to avoid,
and this would have been the clearest instance of it in six phases.

**Accepted cost, and it is not small.**

The guarantee is inherited rather than engineered, which means nothing in this
repository protects it. A future change that moves the worker from a schedule
to something else — a long-running process, a queue consumer, anything that
keeps its own state between runs — loses the property silently, because
nothing here is asserting it. There is no test that fails.

The boundary is also sharper than the guarantee sounds. **Renaming or removing
the workload destroys a run in flight**, demonstrated rather than inferred: a
run four seconds old was destroyed along with the entire retained history of
previous runs, and the delivery controller reported the application healthy
throughout.

That history matters more than it first appears. The worker's health is
answered from the cluster's record of its finished runs, because the process
writes its outcome in the instant before it exits. Destroying that record
leaves the indicator with nothing to read, which is indistinguishable from a
worker that silently stopped. The failure erases the evidence of itself, and
nothing reports it, because by the delivery controller's definition nothing is
wrong — what is committed is what is running.

So the accepted cost of building nothing is that the one real edge is guarded
by a comment in a chart and a paragraph in the architecture document, rather
than by a mechanism. For a reference platform that is the right trade. For a
production system it would not be, and the difference is worth stating because
a reader may be running one.

## Logs are collected, because the one failure this platform automates destroys its own evidence

Metrics have answered *whether* something is wrong since they were added. They
cannot answer *what*, and *what* is the first question anyone asks about a
release that was withdrawn while nobody was watching.

**Why this needed an argument rather than an installation.** The last time this
platform was asked where a fact should come from, the textbook answer was to
install something and the right answer was that the cluster already knew. The
batch worker's health is read from the cluster's record of its finished runs,
not from a push intermediary, because the facts already existed there. Reaching
for a component is the move this platform is supposed to resist, so the
question was asked again: does the cluster already know why something failed?

**For a failed batch run, largely yes.** The run's pod is kept under the history
limits, so its output can be read after it finishes. Bounded, and the bound
matters — the history expires with successive runs, and removing or renaming the
workload destroys all of it at once.

**For a withdrawn release, no.** When the gate abandons a release, the
controller scales the candidate to zero and the pod is deleted; measured
cleanup was 48 seconds after the abort. The output goes with the pod. So the
single failure this entire platform is built around — a bad version caught and
withdrawn automatically, with nobody present — is the one where afterwards
there is nothing to read. The numbers from two such aborts survive only because
they were copied into this file by hand at the time.

**Decision. A store and a collector, four pods, with the same posture as the
metrics stack: one replica, local storage, retention set explicitly to a day,
and declared disposable.** Queried through the Grafana that already exists, as
a second data source, so there is no second console and no new way in.

**Rejected: no collector, read the previous container's output.** The honest
minimum, and it fails on exactly the case above. Named rather than skipped,
because "the cluster already knows" was the correct answer once and the
difference between then and now is the whole reason this entry exists.

**Rejected: Promtail.** The name most people know, and superseded. Its chart
pins a version of the store two minor releases behind the one being installed,
and the collector Grafana now develops is the other one.

**Rejected: the bundled stack chart.** It brings its own Grafana and its own
metrics collector. This platform has both, so it would install a second console
to avoid writing one values file.

**Rejected: object storage for the store.** A bucket, a lifecycle policy and a
pod identity, for data already established as disposable — nothing here claims
persistent storage, so a reschedule loses it before a teardown could. Logs get
the same day of retention as the measurements and the same explicit statement
that losing them costs nothing.

**Rejected: the scalable topology, which is what the chart actually defaults
to.** Its default deployment mode is named for the single-node layout, but its
default replica counts deploy nine pods across three scalable roles and then
refuse to render at all without object storage. The single-node layout has to
be asked for explicitly, in four places, against a default that claims to be it
already.

**Accepted cost.**

Four more pods on a three-node cluster, taking the fullest node from three free
slots to two. That is enough to still absorb a release candidate landing there,
and it is the whole margin.

A day of retention means the evidence for anything older than a day is gone,
including the evidence for a failure nobody looked at over a weekend. The
alternative was a bucket and an identity for a platform that is parked most of
the time.

And the component is only as good as the race it is in. A line reaches the
store if the collector read it before the pod was deleted. For a withdrawn
release that window is the 48 seconds between the abort and the cleanup, which
is wide — but it is a window rather than a guarantee, and a pod that dies
faster than its last lines are shipped loses them. Whether it holds was
measured rather than assumed, and the measurement is recorded with the gate's
other results.

## How long a release may make no progress, and whether giving up does anything

Two settings on the release resource, both moved off their defaults, and
neither is part of the gate. The gate judges a candidate that is serving. These
cover a candidate that never gets that far.

**Two minutes before a release is declared stuck.** Derived rather than picked:
the readiness probe declares failure at seventeen seconds, and two minutes is
roughly seven times that, which covers an image pull onto a cold node and
little else. The default is ten minutes, or thirty-five times the only evidence
available about how long failure takes to become visible.

**Giving up actually withdraws the release.** The default reports the deadline
and takes no action, which leaves a replica set that will never work holding a
pod slot until a person intervenes. On a platform whose claim is that a bad
version is withdrawn with nobody watching, a release that needs a human to
finish failing is not a release that withdraws itself.

**Rejected: leaving both at their defaults.** The honest default position, and
it fails the platform's own claim. Ten minutes of a stalled release is ten
minutes in which the thing that was supposed to happen automatically has not,
and a reported-but-not-acted-on deadline is a notification rather than a
safeguard.

**Rejected: a tighter deadline.** Anything close to seventeen seconds turns a
slow image pull into a withdrawn release. The margin exists for the cold-node
case specifically.

**Accepted cost.** The deadline fires on elapsed time rather than on evidence,
so a release that is slow for a legitimate reason nobody anticipated is
withdrawn exactly as fast as one that is broken. There is no distinction
available at that point, which is the price of acting without a human.

It was also configured and unproven for a phase: the first release it would
have applied to was repaired before the deadline could act. It has since fired
at 123 seconds against a configured 120, with cleanup 48 seconds later.

## Which namespaces may publish through the shared gateway

One gateway serves the whole cluster, and something has to say whose routes it
will accept. The chart's default is the gateway's own namespace, which is the
namespace the ingress controller lives in.

That default is safe and wrong here. A route belongs beside the service it
routes to, and the services live in the environment namespaces. Left alone, the
gateway accepts nothing, and the only way to publish a service would be to put
its route in the ingress controller's namespace, away from the chart that owns
it.

**Decision. Routes are accepted from any namespace carrying the `environment`
label**, which the environment chart puts on every namespace it creates.

**Why a label rather than a list of names.** The rule then reads "any namespace
that is an environment", and a third environment needs no edit here. A list
would need one, and the failure mode of forgetting is a service that deploys
cleanly, reports healthy, and cannot be reached — which is harder to diagnose
than a service that fails to deploy at all.

**Rejected: accepting routes from all namespaces.** One word shorter, and it
would let anything in the cluster publish itself through the front door. The
gateway is the one component here reachable from the internet, so what may
attach to it is the narrowest place to say no.

**Rejected: putting every route in the ingress controller's namespace.** The
default, and it works. Rejected because it separates a service's route from the
chart that owns the service, so publishing a new service means editing two
charts in two namespaces and the route outlives the service if anyone forgets.

**Accepted cost.** Any namespace that carries the label can publish through the
front door, and nothing checks what hostname it claims. Two environments could
in principle both declare a route for the same host, and the result is decided
by the routing layer's own precedence rules rather than by anything stated here.
With two environments owned by one operator that is theoretical; in a cluster
with more than one team in it, this is the point at which the label stops being
sufficient and route ownership needs a real policy.

## The committed views ship once, where the scrape definitions ship per environment

Two kinds of object, both part of observing a service, shipped in opposite
ways. The asymmetry looks like an inconsistency and is the point.

**A scrape definition describes targets in one namespace.** It names what to
collect from, and what to collect from exists once per environment, so one
belongs in each environment and two copies are correct. They are committed
inside each service's own chart.

**A view describes a service across environments** and switches between them
with a selector at the top. It is a single artefact about a single service.

**Decision. The views are their own component, released once, into the
namespace the collector lives in.**

**Why this follows from how the sidecar works.** The component that loads views
watches every namespace for a labelled config map. So shipping views from a
per-environment chart would not produce one view per environment — it would
produce the same view, loaded twice, listed twice in the menu, with nothing to
distinguish the copies. The duplication would be invisible in the repository and
obvious only in the interface.

For the same reason there is no per-environment values file for this component.
The environments a view offers are a property of the view, not of a place it is
deployed to.

**Rejected: putting the views in each service's chart, beside its scrape
definition.** Consistent, and consistency is usually right. Rejected because the
two objects have different scopes, and treating them the same produces the
duplicate-menu-entry failure above.

**Rejected: one chart holding both the views and the scrape definitions.** It
would put everything about observing a service in one place. Rejected because
the scrape definitions genuinely do belong per environment, so the chart would
have to be deployed per environment, which brings the duplication back.

**Accepted cost.** Observing a service is now described in two places — part in
the service's chart, part in a component named for views — and nothing in either
file says the other exists without a reader following the reasoning here. A
reader looking for "everything about metrics for this service" has to know to
look twice.
