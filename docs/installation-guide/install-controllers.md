# Post-install controllers (chart-controller, SUC, cluster-upgrade-controller, machine-config-controller)

A default run of the [installation runbook](install-bootc-mke3.md) deploys
four additional controllers to the cluster, on top of MKE itself: the
`chart-controller`, the System Upgrade Controller (SUC),
`cluster-upgrade-controller`, and `machine-config-controller`. This runbook
covers what each one is, how they are installed, where their versions come
from, and how to verify the result. It does not cover *using* the
controllers day to day — see the
[machine configuration runbook](../operations-guide/machine-config-operations.md) for
`machine-config-controller` and the
[upgrade runbook](../operations-guide/upgrade-with-controller.md) for
`cluster-upgrade-controller`.

## Requirements

1. A cluster installed via the [installation runbook](install-bootc-mke3.md)
   with the default `deploy_chart_controller` and `deploy_suc` flags (both
   `true` in `vars/common-vars.yml`).
2. Cluster access per the [access runbook](../operations-guide/access-cluster.md) — everything
   below uses the MKE client bundle's kubeconfig; no SSH to cluster machines
   is required.
3. `kubectl` on the machine running Ansible and on your workstation. `helm`
   is only needed on your workstation to *inspect* the installed releases
   (`helm ls`); it is no longer part of the install path.

## Procedure

### What gets deployed

| Controller | Namespace | Installed by | Purpose |
|---|---|---|---|
| `chart-controller` | `kube-system` | Ansible (`kubectl apply` of an image-rendered manifest) | Reconciles `Chart` custom resources (`helm.k0sproject.io/v1beta1`), installing and upgrading the referenced Helm charts in-cluster. Vendored from k0s's embedded helm controller (Apache-2.0); built and staged by bootc-mirantis. |
| System Upgrade Controller (SUC) | `system-upgrade` | Ansible (`kubectl apply` of node-fetched manifests) | Runs the per-node `Plan` jobs that `cluster-upgrade-controller` and `machine-config-controller` both drive. Install also patches it with a control-plane-only node affinity, a longer job active-deadline, and a privileged pod-security grant for its service account. |
| `cluster-upgrade-controller` | `mke` | `chart-controller` (from a `Chart` CR) | Reconciles `ClusterUpgrade` custom resources (whole-cluster OS + product upgrades). |
| `machine-config-controller` | `system-upgrade` (see note below) | `chart-controller` (from a `Chart` CR) | Reconciles `MachineConfigChange` custom resources — see the [machine configuration runbook](../operations-guide/machine-config-operations.md). |

`machine-config-controller`'s Helm release lives in the `mke` namespace, but
its chart hardcodes `targetNamespace: system-upgrade` internally — the
deployed pod lands in `system-upgrade` regardless of the release namespace.
Look there, not in `mke`, when inspecting it.

### How installation works

Controller installation no longer runs `helm` on the Ansible controller.
Instead:

1. During `mke-install-playbook.yml`, while SSH to the nodes still exists,
   `tasks/fetch-chart-controller-apply-tasks.yml` copies four small rendered
   manifests (a few KB of YAML total) from a node's
   `/usr/share/mke-controllers/apply/` down to
   `{{ playbook_dir }}/mke-bundle/apply/`:
   `helm.k0sproject.io_charts.yaml` (the `Chart` CRD),
   `machine-config-controller-crds.yaml`, `chart-controller.yaml` (the
   controller Deployment/RBAC), and `charts.yaml` (one `Chart` CR per
   bundled controller). SUC's manifests are fetched alongside by
   `tasks/fetch-controller-manifests-tasks.yml`, unchanged — SUC is plain
   YAML, not a chart, and stays on its existing path.
2. The post-install play (`tasks/chart-controller-tasks.yml`, MKE API only,
   no SSH) `kubectl apply`s the `Chart` CRD, the `machine-config-controller`
   CRDs, and the `chart-controller` Deployment; waits for the rollout; then
   applies the `Chart` CRs and polls each one until `.status.releaseName` is
   set with an empty `.status.error`.
3. The `chart-controller` pod — scheduled on a control-plane node, running
   the `localhost/chart-controller:<version>` image that
   `mke-images.service` docker-loaded at boot (`imagePullPolicy: Never`; the
   image is never pulled from a registry) — installs each chart from the
   node-local path in the CR (`/usr/share/mke-controllers/manifests/<name>-chart`,
   mounted read-only via hostPath) into the release name and namespace baked
   into the CR.

Nothing in this flow contacts a registry: the controller image, both charts,
and every pod image the charts reference were staged into the bootc image at
build time.

### In-image sources are the source of truth

On any booted cluster node, `/usr/share/mke-controllers/` holds exactly what
that image build baked in:

- `versions.txt` — the exact image references/tags for every controller and
  upgrade-job image shipped in this build, including `chart-controller`
  itself. Always read a controller's version from this file on a live node.
  Never hand-guess a tag, or copy one from a previous build, an example in
  this doc, or memory — a wrong reference typically doesn't fail fast, it
  fails only after burning through a long-running operation's timeout.
- `manifests/` — the literal SUC manifests, plus the
  `cluster-upgrade-controller` and `machine-config-controller` chart
  sources, staged unmodified at image-build time.
- `apply/` — the rendered bootstrap manifests described above, including the
  `Chart` CRs whose `spec.version` fields were rendered at image-build time
  to match the staged charts exactly.

Controller versions are pinned at image-build time (bootc-mirantis
`MKE_UPGRADE_CONTROLLER_VERSION` / `MACHINE_CONFIG_CONTROLLER_VERSION` /
`CHART_CONTROLLER_VERSION`) and flow into the rendered `Chart` CRs. There
are no per-controller version variables in Ansible anymore — the single
`deploy_chart_controller` flag controls the whole bundle.

### CRD lifecycle

Helm installs a chart's `crds/` directory on first install only and never
touches it again on upgrade (Helm's own convention, by design, to avoid
destructive schema changes). To keep CRDs in sync anyway:

- `machine-config-controller`'s CRDs are rendered into
  `apply/machine-config-controller-crds.yaml` at image-build time and
  `kubectl apply`d explicitly on every install, ahead of the chart.
- `cluster-upgrade-controller`'s CRDs come from its chart's `crds/` at first
  install and are **not** auto-reapplied — if a newer image build bumps its
  chart with a CRD schema change, apply
  `/usr/share/mke-controllers/manifests/cluster-upgrade-controller-chart/crds/*.yaml`
  (node-fetched or via `kubectl debug`) by hand.

### Changing a controller's version

The supported path is building a bootc image with different version pins and
rolling it out — versions are image content, not install-time inputs.

For ad-hoc day-2 experiments only: `kubectl edit chart <name> -n kube-system`
and point `spec.chartName` at an `oci://` chart reference with the desired
`spec.version`. The controller reconciles the change as a Helm upgrade. This
requires the chart registry to be reachable from the `chart-controller` pod
and the referenced pod images to be pullable by the nodes — both are network
dependencies a default install does not have — and drifts the cluster from
its image; the next image rollout's CRs won't know about it.

### Verify

Check the `Chart` CRs first — they are the install's own status report:

```sh
kubectl get chart -n kube-system \
  -o custom-columns=NAME:.metadata.name,RELEASE:.status.releaseName,VERSION:.status.version,ERROR:.status.error
```

Then confirm every controller pod image matches `versions.txt` exactly:

```sh
kubectl get deploy chart-controller -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get deploy cluster-upgrade-controller -n mke \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get deploy machine-config-controller -n system-upgrade \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get deploy system-upgrade-controller -n system-upgrade \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

A mismatch is otherwise invisible until something depending on the newer
image's behavior fails.

## Expected Results

- Both `Chart` CRs show `.status.releaseName` set, `.status.version` equal
  to the chart version staged on the nodes, and an empty `.status.error`.
- `helm ls -n mke` shows `cluster-upgrade-controller` and
  `machine-config-controller` as `deployed`, revision 1 on a fresh install.
- `kubectl get deploy` in `kube-system`, `mke`, and `system-upgrade` shows
  every controller above `1/1` ready.
- The relevant CRDs are present (confirm the exact spelling with
  `kubectl get crd` on your cluster): `charts.helm.k0sproject.io`, SUC's own
  `plans.upgrade.cattle.io`, `cluster-upgrade-controller`'s
  `clusterupgrades.upgrade.mirantis.com`, and `machine-config-controller`'s
  `machineconfigchanges.config.machine-config-controller.io`.
- Restarting the `chart-controller` pod is a no-op: Helm revisions stay
  unchanged (the reconciler short-circuits when the CR status matches the
  spec), so controller restarts and node reboots do not churn releases.

## Troubleshooting

| Symptom | Likely cause | Remediation |
|---|---|---|
| A `Chart` CR's `.status.error` is non-empty, or the install's "Wait for each Chart release to install" task exhausts its retries | The chart install failed in-cluster | `kubectl logs deploy/chart-controller -n kube-system` has the full Helm error; the CR status carries the last one-line summary |
| `Chart` CRs exist but `.status` stays empty | `chart-controller` pod not running or not leader | `kubectl get pods -n kube-system -l app=chart-controller`; check the deployment's node affinity — it requires a control-plane node |
| `kubectl apply` on a `MachineConfigChange` (or `ClusterUpgrade`) fails `strict decoding error: unknown field ...` | The CRD is stale relative to the chart actually installed — possible for `cluster-upgrade-controller` (no auto CRD re-apply) | Apply the chart's `crds/*.yaml` from `/usr/share/mke-controllers/manifests/` (see CRD lifecycle above) |
| A controller's pod image doesn't match `versions.txt` | A `Chart` CR was hand-edited to an `oci://` reference (see "Changing a controller's version") | Revert the CR to the node-local `chartName`/`version` from the image's `apply/charts.yaml`, or finish the version change properly with a new image build |
| `machine-config-controller` deployment not found in namespace `mke` | Its chart hardcodes `targetNamespace: system-upgrade`; look there instead | Not a fault — expected behavior |
| Locked out of SSH and sudo on every node | `disable_sshd_after_install`/`revoke_sudo_after_install` ran during install, before the controller installs (see [install runbook](install-bootc-mke3.md#post-install-automation)) | Break-glass recovery below |

### Break-glass recovery: locked out of SSH and sudo

If a default install already ran `disable_sshd_after_install` /
`revoke_sudo_after_install`, recover access entirely through the MKE client
bundle's kubeconfig — no SSH to the node required:

```sh
export KUBECONFIG=<bundle>/kube.yml
kubectl debug node/<node-name> --image=busybox -- chroot /host /bin/sh -c '
  systemctl enable --now sshd
  usermod -aG wheel <ansible-user>
  install -d -m 0700 /etc/sudoers.d
  echo "<ansible-user> ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-cloud-init-users
  chmod 440 /etc/sudoers.d/90-cloud-init-users
'
```

`kubectl debug node/<node>` schedules a privileged pod on the target node
and tolerates the node's own readiness taints automatically, so it works
even against a node `kubectl` doesn't consider healthy. `chroot /host` gives
the debug pod's shell the node's real root filesystem. Restoring wheel-group
membership alone is not sufficient — Rocky's default `%wheel` sudoers line
still prompts for a password — so the NOPASSWD drop-in above is required to
get non-interactive sudo back. Repeat for each locked-out node.

This restores the access a run with `disable_sshd_after_install: false` /
`revoke_sudo_after_install: false` would have left in place; it does not
change the `vars/common-vars.yml` defaults themselves, so re-running the
install playbook without an override reapplies the lockout.

## F.A.Q

### Can I skip installing one of these controllers?

- `deploy_chart_controller: false` skips the chart-controller bootstrap and
  with it both `cluster-upgrade-controller` and `machine-config-controller`
  — they are installed *by* it. There is no per-controller flag anymore; to
  run one without the other, delete the unwanted `Chart` CR after install
  (the controller uninstalls the release via its finalizer).
- `deploy_suc: false` skips SUC. Note `cluster-upgrade-controller` depends
  on SUC being present for OS-level upgrade steps.

### Why does the chart-controller have cluster-admin?

It installs arbitrary Helm charts, whose manifests can contain any resource
kind in any namespace. Scoping it more tightly would break on the first
chart that ships a new resource type. Accepted for the current design; see
the [controller security analysis](../operations-guide/controller-security-analysis.md)
for the wider threat model.

### Where is this documented upstream?

`cluster-upgrade-controller` and `machine-config-controller` are both
Mirantis projects with their own docs (architecture, CRD reference,
operational runbooks) in their respective repositories; SUC is
[rancher/system-upgrade-controller](https://github.com/rancher/system-upgrade-controller).
`chart-controller` lives in the bootc-mirantis repository
(`chart-controller/`) and is a standalone extraction of
[k0s](https://github.com/k0sproject/k0s)'s embedded helm extensions
controller — the `Chart` CRD and its `helm.k0sproject.io` API group are
k0s's, unchanged.
