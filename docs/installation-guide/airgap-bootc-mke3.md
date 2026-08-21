# Air-gapped bootc-mke3

Instructions and prerequisites on how to properly install and upgrade bootc-mke3 in an air-gapped environment.

See also: [Install bootc-mke3](install-bootc-mke3.md), [Post-install controllers](install-controllers.md), [Upgrade bootc-mke3](../operations-guide/upgrade-with-controller.md) (or the [Ansible exception path](../operations-guide/upgrade-with-ansible.md)).

## Prerequisites

- `kubectl` on the machine where Ansible runs. `helm` is no longer required
  for installation — controllers are installed in-cluster by the
  `chart-controller` from charts staged on the nodes (see the
  [controllers runbook](install-controllers.md)).

## What the image already makes air-gap-safe

The controller stack is designed to need no network at install time. The
bootc image bakes in, and the install consumes only:

| Artifact | How it reaches the cluster |
|---|---|
| `chart-controller` bootstrap manifests (`Chart` CRD, `machine-config-controller` CRDs, controller Deployment, `Chart` CRs) | Rendered into the image at build time (`/usr/share/mke-controllers/apply/`), fetched from a node to the Ansible controller, `kubectl apply`d over the MKE API |
| `chart-controller` container image | Docker-loaded on every node at boot by `mke-images.service` (`imagePullPolicy: Never` — never pulled from any registry) |
| `cluster-upgrade-controller` and `machine-config-controller` Helm charts | Staged in the image (`/usr/share/mke-controllers/manifests/*-chart`), installed in-cluster by the `chart-controller` from the node-local path — never fetched to the Ansible controller, never pulled from a chart registry |
| Container images referenced by those charts (controller + agent pods, upgrade-job images) | Docker-loaded at boot by `mke-images.service`; the tags baked into the charts match `versions.txt`, so kubelet finds them locally and never pulls |
| System Upgrade Controller CRDs/manifest | Staged in the image (`/usr/share/mke-controllers/manifests/`), fetched from a node, `kubectl apply`d — the SUC image tag inside the manifest is likewise preloaded |

None of the rows above need mirroring or variable overrides for a default
install.

## What must still be mirrored to reach full air-gap

| Artifact | Pulled by | Reachable from | Default source | Mirror via |
|---|---|---|---|---|
| MKE (`mirantis/ucp` and the images it fans out to) | `docker` on every node during `mirantis/ucp ... install` (and again during product upgrades) | targets | `docker.io` | Mirror the MKE image set for your MKE version to an internal registry; point the targets at it with a `daemon.json` containing `registry-mirrors` via `vars/common-vars.yml: docker_daemon_config_src`, and register credentials with `reg-creds-playbook.yml` |
| bootc OS image for day-2 upgrades | `bootc switch` / `bootc upgrade` (`tasks/bootc-upgrade-tasks.yml`, or a `ClusterUpgrade` CR's `spec.os.image`) | targets | `registry.mirantis.com` | `vars/upgrade-vars.yml: bootc_image_ref` (Ansible path) or the CR's `spec.os.image` (controller path) — point at your internal OCI registry; `reg-creds-playbook.yml` writes `/etc/ostree/auth.json` for the pull |

Practically: a fully air-gapped **install** needs the MKE image set
reachable from the targets; a fully air-gapped **day-2** additionally needs
the bootc OS image mirrored for upgrades. Everything controller-related
ships inside the image itself.

Note on hand-edited `Chart` CRs: pointing a CR's `spec.chartName` at an
`oci://` reference (see the [controllers runbook](install-controllers.md))
reintroduces a network dependency — the chart registry must be reachable
from the `chart-controller` pod and the referenced pod images from the
nodes. Don't do this in an air-gapped cluster unless both are mirrored.

## Ansible variables to set

### `vars/reg-creds` (copy from `vars/reg-creds.example`, gitignored)

One line per registry, `registry username password`. The playbook for setting registry credentials ([`reg-creds-playbook.yml`](../../ansible/reg-creds-playbook.yml)) uses this to:

1. `docker login` each registry on every target host.
2. Write `/etc/ostree/auth.json` on every target host — needed for
   `bootc switch`/`bootc upgrade` pulls.

List **every** registry host you actually pull from in air-gap —
typically your internal mirror host(s) standing in for `docker.io`
(MKE images) and `registry.mirantis.com` (bootc OS image). Run
`reg-creds-playbook.yml` before `mke-install-playbook.yml`.

### `vars/common-vars.yml`

| Variable | Default | Air-gap action |
|---|---|---|
| `docker_daemon_config_src` | `""` | Set to a `daemon.json` with `registry-mirrors` populated so the targets transparently redirect `docker.io` pulls (the MKE image set) to your mirror |
| `deploy_chart_controller` | `true` | No action needed — the whole controller bundle (chart-controller, `cluster-upgrade-controller`, `machine-config-controller`) installs from in-image sources. Set `false` only to skip the bundle entirely |
| `deploy_suc` | `true` | No action needed — manifests and image come from the in-image sources. Set `false` if you don't need scheduled OS/MKE upgrades |
| `suc_crd_manifest_src` | `{{ playbook_dir }}/mke-bundle/controller-manifests/system-upgrade-controller-crd.yaml` (node-fetched) | Override only if you deliberately want a different SUC version than the one preloaded on this image, **or** if running `mke-post-install-playbook.yml` standalone from a different controller/directory than the one that ran install — point at a local path or internal mirror URL |
| `suc_controller_manifest_src` | `{{ playbook_dir }}/mke-bundle/controller-manifests/system-upgrade-controller.yaml` (node-fetched) | Same as above — and the image reference *inside* whatever manifest you point at must be reachable from cluster nodes |

There are no per-controller chart/version variables anymore:
`cluster-upgrade-controller` and `machine-config-controller` versions are
pinned at image-build time into the rendered `Chart` CRs. To deploy
different controller versions, build an image with different pins
(bootc-mirantis `MKE_UPGRADE_CONTROLLER_VERSION` /
`MACHINE_CONFIG_CONTROLLER_VERSION`).

## Checklist

1. Mirror the MKE image set for your target MKE version to an internal
   registry reachable from the nodes; note the hostname.
2. Mirror the bootc OS image you will upgrade to (day-2) and note its ref.
3. Create `vars/reg-creds` with every mirror registry host + credentials.
4. Set `docker_daemon_config_src` to a `daemon.json` with `registry-mirrors`
   pointing at your mirror.
5. Run `reg-creds-playbook.yml`, then `mke-install-playbook.yml`. No
   controller-related overrides are needed — verify afterwards per the
   [controllers runbook](install-controllers.md#verify).
