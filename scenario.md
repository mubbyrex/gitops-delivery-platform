# Scenario

**This scenario is invented.** Northwind Payments does not exist. There are
no real merchants, no real money, and no real card data anywhere in this
repository. The two services described below are stubs: they expose a health
endpoint, a metrics endpoint, and a switch that makes them fail on purpose.
They do not implement payment logic and they are not going to grow toward
implementing it.

The scenario exists because release safety is hard to demonstrate in the
abstract. It needs two workloads whose delivery requirements genuinely
conflict, so that the difference between them has to be designed rather than
asserted.

---

## The business

Northwind Payments authorises card payments for online merchants, then pays
those merchants what they are owed.

Those are two different jobs with two different shapes, and they are handled
by two different services.

---

## payments-api

Synchronous request/response over HTTP. A merchant's checkout calls it, it
authorises or declines, it answers. It holds no session state between
requests, so it runs as many identical replicas behind a load balancer and
scales by adding more of them.

Three properties follow from that shape:

- **Two versions can run at the same time without interfering.** A request
  handled by the old version and a request handled by the new version have
  nothing to do with each other.
- **A small share of traffic is a small share of the consequence.** Send two
  percent of requests to a new version and at most two percent of requests
  are affected by whatever is wrong with it.
- **Damage is visible almost immediately.** Error rate and latency move
  within seconds, on a request volume high enough to be statistically
  meaningful straight away.

A service with those three properties can be released gradually: run both
versions, send the new one a slice of live traffic, watch the indicators that
matter, and either widen the slice or take it away.

---

## settlement-worker

Batch. It wakes on a schedule, reads the payments captured since it last
ran, works out what each merchant is owed, and issues one payout per
merchant to an external banking partner.

It has none of the three properties above.

- **Two versions running at once is the failure, not a mitigation.** Both
  read the same unsettled payments, both decide a payout is owed, and the
  merchant is paid twice. The second payout has already left the account by
  the time anyone notices.
- **A small share of the work is not a small share of the harm.** There is no
  meaningful sense in which two percent of a settlement run is a safe
  experiment. Two percent of merchants paid twice is an incident, and
  recovering the money is a negotiation with someone else's bank rather than
  a rollback.
- **Damage is invisible until much later.** The run looks like it succeeded.
  The duplicate surfaces on a reconciliation report, or in a phone call from
  the merchant, hours or days afterwards.

The underlying reason is that the worker's real output is not a response.
It is an irreversible side effect in a system this platform does not
control. You cannot un-send a payment by scaling a deployment to zero.

---

## Why the asymmetry is the point

Gradual release rests on assumptions that are so reliably true of stateless
web services that they usually go unstated: that versions can coexist, that
exposure can be metered, and that you will find out you were wrong while the
exposure is still small.

`payments-api` satisfies all three. `settlement-worker` satisfies none of
them. The same release mechanism cannot be correct for both, and a platform
that applies one strategy uniformly has misread at least one of these two
workloads.

So the worker is delivered on a different principle. Rather than limiting how
much of the traffic a new version sees, the platform limits *when* a new
version is allowed to appear at all: one version of the worker exists at a
time, a new version is only permitted to take over while no run is in
flight, and a run that is already in progress is never overlapped by a
second one. The safety property being enforced is that no two versions ever
touch the same batch of payments — not that a bad version can be withdrawn
quickly, because by then the payouts have already been made.

Encoding that difference, and being explicit about what each choice costs, is
what this repository is for.

---

## What this repository is

A reference platform. It exists so that a set of delivery and release-safety
decisions can be seen working in one place, and so the reasoning behind each
one is written down next to it.

It is not a reusable tool and nothing should depend on it. The interesting
content is the configuration and the reasoning in `docs/`, not the service
code, which is deliberately trivial.
