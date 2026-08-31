# Collect support bundles from nodes

How to collect diagnostic bundles from every `bootc-mke3` node at once through
the Kubernetes API, without SSH. One Job per node runs a fixed set of
collectors — systemd journal, MCR state, the MKE 3 node support bundle, `bootc`
deployment status, and general host state — and writes a single
`<name>-<node>-<timestamp>.tar.gz` to each destination you configure.

This is the bulk path for Day-2 diagnostics and for producing data a support
case asks for. For interactive investigation of one node, use
[Open a debug shell on a node](node-debug-shell.md).

## Security

A capture is **root-equivalent on every node it runs on**: each Pod is
privileged, joins the host PID namespace, mounts the host root filesystem at
`/host`, and runs host commands via `nsenter --target 1`. Treat the ability to
create these Jobs as `cluster-admin` on the cluster's nodes.

The bundles themselves are sensitive. They contain journal output, daemon
configuration, and the MKE support bundle; handle and transport them as
confidential data, and delete them from nodes once they are collected.

## Requirements

1. `kubectl` configured from an MKE client bundle — see
   [Access the cluster](access-cluster.md).
2. The privilege grant and the `cluster-support` namespace from
   [Run privileged support containers on MKE](privileged-support-containers.md).
3. `envsubst` (package `gettext`/`gettext-base`) on your workstation.
4. The cluster's MKE version for the image tag, as in
   [the debug shell runbook](node-debug-shell.md#requirements). The collector
   image is `mirantis/ucp-dsinfo:<MKE version>`; in an air-gapped cluster,
   mirror it and use the local reference in the Job template.

## Files

All three live in [`docs/examples/cluster-support/`](../examples/cluster-support):

| File | Purpose |
|---|---|
| [`capture-scripts-configmap.yaml`](../examples/cluster-support/capture-scripts-configmap.yaml) | The collector scripts, mounted at `/scripts`. Applied once per cluster. |
| [`capture-job.yaml.tmpl`](../examples/cluster-support/capture-job.yaml.tmpl) | One Job per node. `${NODE_NAME}` is its only template variable. |
| [`s3-credentials-secret.yaml.example`](../examples/cluster-support/s3-credentials-secret.yaml.example) | Credentials skeleton, only for the S3 destination. |

## Procedure

### 1. Install the collector scripts

Once per cluster (re-apply after editing the scripts):

```sh
cd docs/examples/cluster-support
kubectl apply -f capture-scripts-configmap.yaml
```

### 2. Start a capture

Edit the image tag in `capture-job.yaml.tmpl` to match your MKE version, then
fan out over the nodes you want. Note `kubectl create`, not `kubectl apply`:
the Job uses `generateName`, which `apply` rejects.

```sh
# Every node
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  NODE_NAME=$node envsubst < capture-job.yaml.tmpl | kubectl create -f -
done

# Only managers
for node in $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
  NODE_NAME=$node envsubst < capture-job.yaml.tmpl | kubectl create -f -
done

# One node
NODE_NAME=<node-name> envsubst < capture-job.yaml.tmpl | kubectl create -f -
```

### 3. Monitor to completion

```sh
kubectl -n cluster-support get jobs -l app=log-capture -w
```

A capture that includes the `mke3` collector takes minutes per node — that
collector runs MKE's own support command with a 20-minute timeout. To block
until every Job is done:

```sh
kubectl -n cluster-support wait --for=condition=complete job -l app=log-capture --timeout=45m
```

That command only returns successfully if *all* Jobs succeed. If it times out,
list the outcome per node instead of waiting further:

```sh
kubectl -n cluster-support get jobs -l app=log-capture \
  -o custom-columns='JOB:.metadata.name,NODE:.metadata.annotations.support\.mirantis\.com/node,STATUS:.status.conditions[-1].type'
kubectl -n cluster-support logs job/<job-name>
```

### 4. Retrieve the bundles

With the default `hostPath` destination the bundle stays on the node it came
from, at `/var/log/cluster-support/<name>-<node>-<timestamp>.tar.gz`. Open a
[debug shell](node-debug-shell.md) on that node and copy it out — no SSH
involved:

```sh
NODE_NAME=<node-name> envsubst < debug-shell-pod.yaml.tmpl | kubectl apply -f -
kubectl -n cluster-support exec debug-shell-<node-name> -- ls -lh /host/var/log/cluster-support/
kubectl -n cluster-support cp \
  debug-shell-<node-name>:/host/var/log/cluster-support/<bundle>.tar.gz ./<bundle>.tar.gz
kubectl -n cluster-support delete pod debug-shell-<node-name>
```

Use the PVC or S3 destination instead when you want every node's bundle to
arrive in one place without this step.

### 5. Clean up

```sh
kubectl -n cluster-support delete job -l app=log-capture
```

Finished Jobs also delete themselves an hour after completion
(`ttlSecondsAfterFinished: 3600`). Bundles written to a node's
`/var/log/cluster-support` are **not** cleaned up — delete them from the debug
shell once collected.

## What is collected

Every collector writes its command output into the bundle, one file per
command. `collectors.txt` in the bundle records each collector's exit code.

| Collector | Collects |
|---|---|
| `journal` | `journalctl` for the current boot (bounded by `JOURNAL_SINCE`), the previous boot, error-priority entries, `--list-boots`, and per-unit logs for `docker`, `swarm-join`, `mke-images`, and `kubelet`. |
| `mcr` | `docker version`/`info`/`ps -a`, `/var/lib/docker` disk usage, `/etc/docker/daemon.json`, and `docker logs` for `ucp-proxy`, `ucp-reconcile`, `ucp-controller`, `ucp-auth-api`, `ucp-auth-store`. |
| `mke3` | The MKE 3 node support bundle (`mirantis/ucp … support`, 20m timeout) plus the local `/_ping` health probe. Skips with `mke3-skipped.txt` on nodes without `ucp-proxy`. |
| `bootc` | `bootc status --format json` and `rpm-ostree status --json`. |
| `system` | `uname -a`, failed systemd units, `df`, `free`, `ip addr`/`route`, `dmesg`, `sysctl -a`, `getenforce`, `/etc/os-release`. |

Two environment variables in the Job tune the run; both are present but
commented in the template:

| Variable | Effect |
|---|---|
| `COLLECTORS` | Space-separated collector names, e.g. `"journal system"`. Unset runs all five. |
| `JOURNAL_SINCE` | Passed verbatim to `journalctl --since`. Default `24 hours ago`. |

The `mke3` collector is the slow one. Dropping it (`COLLECTORS: "journal mcr
bootc system"`) turns a multi-minute capture into a fast one, at the cost of the
MKE-level bundle a support case usually wants.

## Destinations

A destination is enabled by mounting it or by setting its bucket — the Job
manifest is the only place that decides. Any combination works, and every
enabled destination receives the same tarball.

| Destination | Enabled by | Behaviour |
|---|---|---|
| hostPath | `/out` mounted (default: `hostPath: /var/log/cluster-support`, `DirectoryOrCreate`) | Writes the bundle onto the node itself. Retrieve it with a debug shell, as in step 4. |
| PVC | `/pvc` mounted | Copies the bundle into an existing claim, so all nodes' bundles land together. |
| S3 | `S3_BUCKET` set | Uploads to an S3-compatible endpoint. |

### PVC

Uncomment the `bundles` volume and its `/pvc` mount in the Job template and set
`claimName` to a claim that already exists in `cluster-support` — nothing here
creates or deletes claims.

The claim **must be `ReadWriteMany`** when capturing more than one node at a
time: one Pod per node mounts it concurrently. With `ReadWriteOnce`, Pods on
every other node stay `Pending` until `activeDeadlineSeconds` (2400s) expires
and their Jobs fail. For a `ReadWriteOnce` claim, capture one node at a time.

### S3

Create the Secret (keys `accessKeyID` and `secretAccessKey`), then uncomment
the six S3 environment entries in the Job template:

```sh
kubectl -n cluster-support create secret generic s3-credentials \
  --from-literal=accessKeyID=<key-id> \
  --from-literal=secretAccessKey=<secret>
```

The object is written to
`<S3_ENDPOINT>/<S3_BUCKET>/<S3_PREFIX><name>-<node>-<timestamp>.tar.gz`.
`S3_PREFIX` is a literal prefix — include the trailing `/` if you want a
folder. `S3_REGION` defaults to `us-east-1` when unset, which matters because it
is part of the request signature.

The upload uses `curl --aws-sigv4`, which requires curl 7.75 or newer in the
collector image; `mirantis/ucp-dsinfo` (Ubuntu 22.04 based, curl 7.81) has it.
If you substitute a different collector image whose curl is older, the capture
logs `this image's curl lacks --aws-sigv4` and the other destinations still
receive the bundle. Uploads are bounded (`--connect-timeout 30 --max-time 300
--retry 3`) so an unreachable endpoint fails the destination instead of holding
a privileged Pod on the node.

## Failure semantics

A capture is deliberately fault-tolerant — the node needing a bundle is often
already broken:

- A collector command that fails writes its stderr to `<file>.err` beside the
  output file and does not abort the bundle. An `.err` file present in a bundle
  always means that command actually failed; empty ones are removed.
- `collectors.txt` records `<collector> <exit-code>` per collector, so the
  bundle states what ran.
- A Job **fails only when no destination received the tarball**. Partial
  collection is a success.
- `backoffLimit: 0` means a failed Job is not retried. Read
  `kubectl -n cluster-support logs job/<job-name>`, fix the cause, and create
  the Job again for that node.

## Concurrency

The loop in step 2 starts one privileged Job per matched node simultaneously.
That is intended for a handful of nodes, but on a large cluster it means a
concurrent `mirantis/ucp support` run on every node at once. Capture in slices
instead:

```sh
# Ten nodes at a time
kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' > nodes.txt
split -l 10 nodes.txt batch-

for node in $(cat batch-aa); do
  NODE_NAME=$node envsubst < capture-job.yaml.tmpl | kubectl create -f -
done
kubectl -n cluster-support wait --for=condition=complete job -l app=log-capture --timeout=45m
# retrieve, delete the Jobs, then repeat with batch-ab
```

## Expected Results

- One Job per targeted node, each reaching `Complete`:
  `kubectl -n cluster-support get jobs -l app=log-capture`.
- On each node, `/var/log/cluster-support/<name>-<node>-<timestamp>.tar.gz`
  exists (visible from a [debug shell](node-debug-shell.md) at
  `/host/var/log/cluster-support/`).
- Inside a bundle: `collectors.txt` listing each collector with exit code `0`,
  and — on an MKE node — a non-empty `mke3-support.tgz`.

## F.A.Q

### Can I add my own collector?

Yes. Add a `<name>.sh` key to the ConfigMap that sources `common.sh` and uses
its `collect` helper, re-apply the ConfigMap, and name it in `COLLECTORS`. The
helper handles the host namespace entry, output capture, and never aborting the
bundle.

### Why one Job per node instead of a DaemonSet?

A capture is a task that finishes. Jobs give per-node success/failure,
`backoffLimit: 0` semantics, and self-reaping via `ttlSecondsAfterFinished`; a
DaemonSet would restart the collectors forever and gives no per-node outcome.

### Why is the Pod `Pending`?

A pinned Pod (`spec.nodeName`) is never scheduled, so `Pending` means the
kubelet has not accepted it — a taint the toleration does not cover, a bad node
name, a `ReadWriteOnce` PVC already mounted elsewhere, or a down kubelet. See
`kubectl -n cluster-support describe pod <name>`.

### The Job was rejected at creation.

Admission denied it; the message names the requested attributes and the
ServiceAccount. Re-check [the privilege grant](privileged-support-containers.md)
and that you are creating in `cluster-support`.

### Do the bundles include the MKE cluster-wide support dump?

No. Each Job collects the node it runs on, including that node's
`mirantis/ucp … support` output. For a cluster-level dump, use MKE's own
support bundle from the MKE UI or API.
