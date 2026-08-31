# Run privileged support containers on MKE

Support tooling for a `bootc-mke3` node runs as a privileged container on that
node: it needs the host root filesystem, the host PID namespace, and
`nsenter --target 1` to reach host binaries such as `journalctl`, `docker`, and
`bootc`. MKE 3 rejects such pods by default. This runbook grants one
ServiceAccount the privilege attributes those pods request.

It is the shared prerequisite for:

- [Open a debug shell on a node](node-debug-shell.md)
- [Collect support bundles from nodes](collect-support-bundles.md)

## Security

**A grant made here is root-equivalent on every node the granted pods land
on.** A privileged pod with the host root filesystem mounted can read every
secret on disk, write every file, and enter every host namespace. Any user with
RBAC `create` on pods in the granted namespace inherits that reach, so treat
that permission like `cluster-admin` on the cluster's nodes, not like a
namespaced resource grant.

Consequences to accept before running the procedure:

- Grant the narrowest ServiceAccount you can, in a namespace created for this
  purpose, and keep `create pods` in it restricted to cluster administrators.
- The grant is persistent cluster configuration. It stays in effect until it is
  removed (see [Revoke the grant](#revoke-the-grant)).

## Requirements

1. An MKE 3 cluster and its URL (`mke_url` in the Ansible inventory).
2. MKE **admin** credentials — the config-toml API is admin-only.
3. A workstation with `kubectl` configured from an MKE client bundle (see
   [Access the cluster](access-cluster.md)), plus `curl`.

## What MKE rejects without the grant

MKE 3's `UCPAuthorization` admission controller denies pods that request
privilege attributes unless the pod's ServiceAccount is on a cluster-level
allowlist. Applying a privileged support pod without the grant fails with:

```text
Error from server: admission webhook "ucp.validating.webhook" denied the request:
[cluster-support:default] lack required permissions to use attributes
[hostbindmounts hostpid privileged]
```

The attribute names in the message correspond to what the pod asked for:
`privileged` (a privileged container), `hostbindmounts` (a `hostPath` volume),
and `hostpid` (`spec.hostPID: true`).

Upstream reference:
[admission controllers for access control](https://docs.mirantis.com/mke/3.9/ops/deploy-apps-k8s/admission-controllers-for-access.html).

## Procedure

### 1. Create the namespace

Both support runbooks use the namespace `cluster-support` and its default
ServiceAccount, so the grant covers exactly one identity:

```sh
kubectl create namespace cluster-support
```

### 2. Grant the privilege attributes

The allowlist lives in the MKE cluster configuration TOML, reachable only
through the `/api/ucp/config-toml` API. Download it, add the ServiceAccount,
and upload it back.

```sh
export MKE_URL=<mke-host-or-ip>          # no scheme
export MKE_USER=admin
export MKE_PASS=<password>
export SA_ENTRY=cluster-support:default   # <namespace>:<serviceaccount>

# 1. Authenticate — returns a bearer token
export TOKEN=$(curl -sk -X POST "https://${MKE_URL}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${MKE_USER}\",\"password\":\"${MKE_PASS}\"}" | jq -r .auth_token)

# 2. Download the current cluster config
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  -o mke-config.toml "https://${MKE_URL}/api/ucp/config-toml"
```

Edit `mke-config.toml`. In the `[cluster_config]` section, ensure both keys
below exist and contain the listed values, creating either key if it is absent
and **preserving any entries already present**:

```toml
[cluster_config]
  priv_attributes_allowed_for_service_accounts = ["hostIPC", "hostNetwork", "hostPID", "hostBindMounts", "privileged", "kernelCapabilities"]
  priv_attributes_service_accounts = ["cluster-support:default"]
```

- `priv_attributes_allowed_for_service_accounts` — the attributes that may be
  granted at all. These six are every attribute the admission controller
  supports.
- `priv_attributes_service_accounts` — the `<namespace>:<serviceaccount>`
  entries that may use them. Append `cluster-support:default` to whatever is
  already there; overwriting this array revokes other components' grants (for
  example the System Upgrade Controller's).

Upload the edited file:

```sh
# 3. Upload the modified cluster config
curl -sk -X PUT -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/toml" \
  --data-binary @mke-config.toml "https://${MKE_URL}/api/ucp/config-toml"

rm -f mke-config.toml     # the file is cluster configuration, not a secret, but do not keep stale copies
```

> Use `-k`/`--insecure` only while MKE still serves its self-signed
> certificate; drop it once MKE has a trusted certificate installed.

The change takes effect on the next admission decision; no MKE restart is
required.

### 3. Verify the grant

Create a pod that requests all three attributes on a real node and check that
admission accepts it. Substitute any node name from `kubectl get nodes`:

```sh
kubectl -n cluster-support run grant-check --image=mirantis/ucp-dsinfo:3.9.5 --restart=Never \
  --overrides='{"spec":{"nodeName":"<any-node-name>","hostPID":true,"containers":[{"name":"grant-check","image":"mirantis/ucp-dsinfo:3.9.5","command":["true"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"h","mountPath":"/host"}]}],"volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'
kubectl -n cluster-support delete pod grant-check
```

Creation succeeding — rather than the webhook denying it with the error above —
proves the grant. The pod runs `true` and exits.

## Automated alternative

This repository already automates the same two API calls for the System Upgrade
Controller: `ansible/tasks/suc-priv-grant-tasks.yml` fetches the config TOML,
runs `ansible/tasks/helpers/suc_priv_grant.py <config.toml> <namespace:sa>`,
and PUTs the result. The helper is idempotent and merges rather than
overwrites, so it is the safer way to edit the arrays by hand as well:

```sh
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  -o mke-config.toml "https://${MKE_URL}/api/ucp/config-toml"
python3 ansible/tasks/helpers/suc_priv_grant.py mke-config.toml cluster-support:default
curl -sk -X PUT -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/toml" \
  --data-binary @mke-config.toml "https://${MKE_URL}/api/ucp/config-toml"
```

Two differences from running the playbook:

- The playbook grants `suc_service_account` (from
  `ansible/vars/common-vars.yml`), not `cluster-support:default`. Pass the
  ServiceAccount you want as the helper's second argument.
- The helper also sets `enable_admin_ucp_scheduling = true` in
  `[scheduling_configuration]`. The support pods in these runbooks do not need
  it: they set `spec.nodeName` directly, which bypasses the Kubernetes
  scheduler and therefore MKE's scheduling restrictions on manager nodes. The
  key is harmless but is a real cluster-wide change — if you do not want it,
  edit the TOML by hand as in step 2 instead.

## Revoke the grant

Remove `cluster-support:default` from `priv_attributes_service_accounts` and
PUT the TOML back, then delete the namespace:

```sh
kubectl delete namespace cluster-support
```

Leaving `priv_attributes_allowed_for_service_accounts` populated is harmless on
its own — it lists what *may* be granted; without an entry in
`priv_attributes_service_accounts` no ServiceAccount can use it.

## Expected Results

- The `grant-check` pod in step 3 is created instead of denied.
- The support pods in [node-debug-shell.md](node-debug-shell.md) and
  [collect-support-bundles.md](collect-support-bundles.md) start on their
  target nodes.

## F.A.Q

### I am an MKE admin — do I need this at all?

Possibly not: admin identities may bypass the attribute check. Run the grant
anyway. The runbooks are written for the `cluster-support:default`
ServiceAccount so that they behave identically for every operator and so that a
capture Job (which runs as a ServiceAccount, not as you) is never denied
mid-run.

### Does this need the MKE Scheduler grant too?

No. Every support pod in these runbooks pins itself with `spec.nodeName`, so
the scheduler is not involved. The pods do carry a toleration for
`node-role.kubernetes.io/control-plane` — a `NoExecute` taint still evicts a
pinned pod.

### Why not a Kubernetes PSA label or a PodSecurityPolicy?

MKE 3's own admission controller runs in addition to Kubernetes pod security
admission and is configured only through the cluster config TOML. Relaxing PSA
on the namespace does not satisfy it.
