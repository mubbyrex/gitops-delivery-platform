# Runbook

Procedures for when something is not working, written before they are needed
rather than discovered under pressure.

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
