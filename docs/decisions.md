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

A second cluster costs about a pound and a half per working session. This
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
runs its own networking agent, service proxy and identity agent — so the
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

**Accepted cost.** A run that is skipped is simply skipped. There is no queue,
no catch-up, and nothing records that a window was missed beyond the absence of
a run — so a worker that consistently overruns its schedule silently does half
the work it should, and the only signal is one that nobody is looking at yet.
Monitoring that is a later concern, and until then this trades a loud failure
for a quiet one. That is the right trade when the loud failure is paying
somebody twice, and it is still a cost.
