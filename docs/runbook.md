# Runbook

Procedures for when something is not working, written before they are needed
rather than discovered under pressure.

---

## Bringing it up and taking it down

```bash
./scripts/up.sh      # build everything, point kubectl at it, wait until healthy
./scripts/status.sh  # what exists right now, and what it is costing
./scripts/down.sh    # destroy everything the two configurations own
```

Those apply and destroy without asking, which is right for a person at a
keyboard and is why they are not run by anything automated.

**The build will not complete without two secrets that already exist in AWS**,
and this repository does not create them:

| secret | what it holds | what happens without it |
|---|---|---|
| `kestrel-pay/platform/argocd-admin` | the console password, as a hash | the controller's secret is never populated and the password reverts to a generated one that changes on every rebuild |
| `kestrel-pay/dev/demo` | a demonstration value | the secret store reports a missing reference and the application that reads it stays unhealthy |

They are deliberately outside this repository — a secret committed is a secret
published — and they are the only things that survive a teardown. See
"Rotating the password" below for how to create the first one.

**A rebuild takes about five minutes** from nothing to every application
healthy, most of it waiting for the cluster's control plane. Applications
arrive in waves and report unhealthy while they wait for their dependencies,
which is normal for the first few minutes and not a fault.

---

## Adding a node to a running cluster

Raising the node count in `terraform/cluster` and applying **will fail**, and
the plan beforehand looks entirely reasonable.

```
InvalidParameterException: Minimum capacity N can't be greater than desired size N-1
```

The reason is that the cluster module deliberately ignores later changes to a
node group's desired size, on the assumption that something inside the cluster
scales it. Nothing here does. So on an existing group the desired size is owned
by nobody: Terraform will not move it, and nothing else will either. An edit to
the count moves the floor and the ceiling, the floor ends up above the untouched
desired size, and the cloud rejects it.

Raise the desired size first, outside this configuration and within the current
ceiling, then apply:

```bash
aws eks update-nodegroup-config \
  --cluster-name <cluster> --nodegroup-name <group> \
  --scaling-config desiredSize=<new count> --region <region>
```

Then the apply agrees with what is already running.

**None of this applies to building from nothing**, where all three numbers are
set at creation and the count in the configuration is simply the count. It only
bites when growing a cluster that is already up.

---

## A release is stuck, or did not happen

**The delivery controller polls every few minutes.** A push does not appear
instantly, and a change can arrive in two stages — the part owned by a
service's own application arrives when that application polls, and the part
held inside an application's configuration arrives only when the root
application polls and updates it. A push that seems to have half-applied is
usually this, and waiting is the fix.

**A release of the request-serving service takes about nine and a half
minutes**, by design: ten percent of traffic, then thirty, then sixty, three
minutes at each step with a gate between them.

```bash
kubectl argo rollouts get rollout payments-api -n dev     # if the plugin is installed
kubectl get rollout -n dev payments-api -o jsonpath='{.status.phase} {.status.message}{"\n"}'
kubectl get analysisrun -n dev        # one per release; holds every measurement taken
```

**If it says `Degraded`**, the release was abandoned. The reason is on the
rollout's `message`, and the measurement that failed — with the value it read
and the time it read it — is on the analysis run, which outlives the release.
Traffic is already back on the previous version; nothing needs doing to make
that happen.

**A release that cannot start at all** — a version that never becomes ready —
is given up on after two minutes and the candidate is scaled to zero. No
traffic ever reaches it. Measured at 123 seconds from the version landing to
the release being abandoned.

To get out of it: commit a working version. There is no button, and rolling
back is immediate rather than gradual, because the version being returned to
is the one already known to work.

---

## The settlement worker has stopped running

Two different situations that look identical in a single number, which is why
the view carries two.

| | time since last **scheduled** | time since last **success** |
|---|---|---|
| running normally | under one period | under one period |
| runs skipped or failing | under one period | **climbing** |
| **not being scheduled at all** | **climbing** | **climbing** |

The third is the one nothing else will tell you about. No counter increments
when a scheduled job stops being scheduled — there is no failure to count,
because nothing ran to fail.

```bash
kubectl get cronjob -n dev settlement-worker
kubectl get jobs -n dev                        # the retained history
kubectl logs -n dev job/<name>
```

**Both numbers also read empty after the worker has been renamed**, because
renaming it destroys every run it ever created. If they went blank and the
workload's name changed recently, that is the cause rather than a stoppage.

---

## Never rename or remove the settlement worker while a run is in flight

Changing its image is safe at any moment. Changing its **name** is not.

The delivery controller sees one object newly declared and one no longer
declared, so it creates the first and removes the second — and every run that
schedule ever created belongs to the second. They go with it, including one in
progress.

Measured: a run four seconds old was destroyed along with the entire retained
history of previous runs, and the controller reported the application healthy
throughout. It is correct to do so by its own definition: what is committed is
what is running. It has no concept of an abandoned batch of payments.

If the name must change, change it when no run is in flight, and know that the
record of past runs goes with it.

---

## Getting into the delivery controller's console

The admin password is a bcrypt hash held in AWS Secrets Manager under
`kestrel-pay/platform/argocd-admin`. The secrets operator writes that hash into
the controller's own secret, so the password is the same after every teardown
and rebuild. The password itself is not stored anywhere in this platform — only
the hash — because the controller never needs the password, only something to
compare against. Keep the password in a password manager.

The console is not reachable from outside the cluster. Its service is
cluster-internal, and the only load balancer in this platform belongs to the
ingress controller, which has no route to it. That is the installed default and
it has not been changed: the console is an administrative interface, and
nothing so far has needed it reachable from the internet.

So it is reached through the API server:

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
# then https://localhost:8080 — the certificate is self-signed, so expect a warning

# or from the command line, in a second terminal
argocd login localhost:8080 --username admin --insecure --grpc-web
```

A consequence worth knowing: reaching the console requires cluster access
already. Anyone who can get to it could have read the password out of the
cluster anyway, which is part of why keeping the password out of Git matters
more than keeping it out of the cluster.

---

## The password does not work

Work through these in order. Each one tells you something the next one
assumes.

**1. Did the hash actually arrive?**

```bash
kubectl -n dev get externalsecret demo-secret
kubectl -n argocd get externalsecret argocd-secret
```

`SecretSynced` and `Ready=True` on both means the mechanism is working and the
problem is the password you are typing, not the platform. If only the second
one is failing, the operator is fine and the problem is that one secret.

**2. If it is not Ready, read why.**

```bash
kubectl -n argocd describe externalsecret argocd-secret | tail -20
kubectl -n external-secrets logs deploy/external-secrets --tail=40
```

The three things that actually go wrong, in the order they are worth checking:

- *The secret does not exist in AWS under that name.* Most likely after a fresh
  start in a new account. Create it — see the rotation section below.
- *The operator cannot assume its role.* The log says an IAM role must be
  associated with the service account. The binding is an AWS-side record, so
  check it exists and names the right namespace and service account:
  `aws eks list-pod-identity-associations --cluster-name <cluster>`. It is
  created by the platform configuration, so a missing one means that
  configuration was not applied after the cluster was rebuilt.
- *The agent is not running.* `kubectl -n kube-system get ds
  eks-pod-identity-agent`. Without it the binding exists and silently does
  nothing.

**3. If the platform was just rebuilt and the operator never synced.**

The controller generates its own password on first start and keeps a copy:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

That is the fallback the whole arrangement rests on. It works only until the
operator writes over the password — after a successful sync this value is stale
and will not log you in.

---

## Rotating the password, or setting it for the first time

This is also the correct way to recover from having lost it. AWS holds the
truth, so change it there rather than against the cluster.

```bash
# choose a password and keep it in a password manager; it is not stored here
read -rs -p "new admin password: " PW; echo

HASH=$(argocd account bcrypt --password "$PW")
MTIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# first time
aws secretsmanager create-secret \
  --region us-east-1 \
  --name kestrel-pay/platform/argocd-admin \
  --secret-string "{\"passwordHash\":\"$HASH\",\"passwordMtime\":\"$MTIME\"}" \
  --tags Key=Project,Value=kestrel-pay-platform Key=Environment,Value=dev

# thereafter
aws secretsmanager put-secret-value \
  --region us-east-1 \
  --secret-id kestrel-pay/platform/argocd-admin \
  --secret-string "{\"passwordHash\":\"$HASH\",\"passwordMtime\":\"$MTIME\"}"

unset PW HASH
```

The operator re-reads hourly. To not wait:

```bash
kubectl -n argocd annotate externalsecret argocd-secret \
  force-sync="$(date +%s)" --overwrite
```

Moving `passwordMtime` forward is what invalidates sessions issued under the
old password. Rotating the hash without it leaves anyone already logged in
logged in.

---

## Last resort: back to a generated password

Only if AWS itself is unreachable and you need in now. This fights the
platform, which will put the hash back on its next sync, so it buys a window
rather than a fix.

```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"data": {"admin.password": null, "admin.passwordMtime": null}}'
kubectl -n argocd rollout restart deploy/argo-cd-argocd-server
```

The server regenerates a password and writes a fresh
`argocd-initial-admin-secret`, which step 3 above reads. Then fix AWS and
rotate properly, because the next sync overwrites this.

---

## The loop this creates, stated plainly

Logging into the delivery controller depends on an operator that the delivery
controller itself deploys. If that operator is broken, the console you would
use to look at why is the thing you cannot reach.

It is a degradation and not a lockout, because every step above runs through
`kubectl` and none of them needs the console. That is the only reason this
trade is acceptable, and it is why the fallback is written here rather than
left to be worked out at the time.
