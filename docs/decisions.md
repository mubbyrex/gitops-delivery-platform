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
