# Where everything is

A map of the repository, and which part to open depending on what you came to
find out.

The short version is in the README. This is the one that assumes you have
decided to stay.

---

## Start here, by question

| if you want to know | open |
|---|---|
| what problem this exists to solve | [`../scenario.md`](../scenario.md) |
| **why the two services are released differently** | [`architecture.md`](architecture.md) — "The two workloads, and why they are shaped differently" |
| why any particular choice was made | [`decisions.md`](decisions.md) — one entry per decision, each with what it cost |
| **what makes a release safe, and the measurement that is easy to miss** | [`decisions.md`](decisions.md) — "What a release is judged on" |
| **who owns which object** | [`architecture.md`](architecture.md) — "The boundary that matters most" |
| what this platform deliberately does not do | [`architecture.md`](architecture.md) — "What this platform does not do" |
| what to do when something is broken | [`runbook.md`](runbook.md) |
| how to run it | [`../README.md`](../README.md) |

---

## The tree

```
terraform/cluster/          the network, the cluster, the nodes, workload identity
terraform/platform/         the delivery controller, and the one Application that
                            points it at this repository

argocd/root/                one file per component the delivery controller manages.
                            Reading this directory tells you what runs in the cluster

charts/payments-api/        the request-serving service: a Rollout, the routing,
                            the release gate and its thresholds
charts/settlement-worker/   the batch service: a CronJob, and nothing resembling
                            a canary
charts/environment/         a namespace and the ceilings that bound it
charts/secret-store/        which AWS secrets this platform expects to exist
charts/service-views/       the committed dashboards
charts/synthetic-traffic/   a request generator, dev only, not part of the platform

environments/dev/           the only place environments differ. One values file
environments/staging/       per service per environment, and nothing else

services/payments-api/      a Go stub: health, metrics, and a switch that breaks it
services/settlement-worker/ the same, on a schedule

scripts/                    up, down, status, validate, and the decisions check
local/                      a kind cluster for work that does not need AWS
docs/                       this file, and the three below it
.github/workflows/          the build pipeline, which cannot reach the cluster
```

---

## The four rules that explain the layout

**One chart per service, identical across environments.** If a value differs
between `dev` and `staging`, it lives in `environments/<env>/<service>.yaml`
and nowhere else. If it is the same in both, it belongs in the chart's
defaults. This is what makes "it worked in dev" mean something.

**`argocd/root/` is a list, not a generator.** One file per component,
written out. A generator would be shorter and would make the inventory
invisible: with a list, `ls` answers "what is deployed", and a missing
component is a missing file rather than a pattern that quietly stopped
matching.

**Terraform owns three Kubernetes objects and no more.** A namespace, the
delivery controller, and the Application that points it here. Everything else
in the cluster is owned by the delivery controller. The boundary is deliberate
and is the subject of its own section in `architecture.md`.

**The pipeline cannot reach the cluster.** It builds, scans, publishes, and
commits an image digest to `environments/dev/`. It holds no cluster credential
and no cloud credential. A release happens because something was committed, not
because a pipeline had permission.

---

## What is not here

**`specs/` and `CLAUDE.md` are not published.** They hold the working
apparatus — requirement identifiers, task checkpoints, the notes to the
operator. That is process, and process is not what this repository is for.

The consequence is that `docs/` is the only record of why anything is the way
it is, so it is written for someone who has never seen the private files and
never will. If a reason is not in `architecture.md`, `decisions.md` or
`runbook.md`, it is not written down anywhere a reader can reach.

**No `prod/`.** Two environments are enough to show that the boundary exists
and where it sits. A third would be more of the same files.

**Nothing is scaffolded ahead of need.** An empty directory waiting for a
future feature is a promise the repository has not kept, so there are none.
