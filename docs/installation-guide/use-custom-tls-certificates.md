# Use your own TLS certificate for MKE

By default MKE serves its web UI/API (`https://<mke_url>`) with a self-signed
certificate that browsers and API clients don't trust. This runbook covers
installing MKE with your own certificate instead, via
`ansible/tasks/mke-external-certs-tasks.yml` and the `--external-server-cert`
install flag.

> This only replaces the **web-server/API-facing** certificate. MKE's
> internal Cluster/etcd/Client root CAs (which issue node-to-node, etcd, and
> client-bundle certificates) are a separate mechanism — see
> [Replace MKE root CA material](../operations-guide/replace-mke-root-ca.md)
> for that instead.

## Requirements

1. A cluster that has **not yet had `mke-install-playbook.yml` run**. This is
   an install-time-only customization — enabling it after MKE is already
   installed does not rotate a live certificate; see the F.A.Q below.
2. A certificate bundle in PEM format:
   - `ca.pem` — root CA public certificate.
   - `cert.pem` — server certificate plus any intermediate CA certificates.
     **Must already include Subject Alternative Names (SANs)** for `mke_url`
     (the ansible inventory var) and any load balancer address used to reach
     MKE — MKE does not add SANs to a certificate you supply, and will reject
     requests for host names not covered.
   - `key.pem` — unencrypted server private key matching `cert.pem`.
3. Ansible inventory ready per the [installation runbook](../installation-guide/install-bootc-mke3.md).

## Procedure

1. In `ansible/vars/common-vars.yml`, set:

   | Variable | Value |
   |---|---|
   | `mke_external_certs_enabled` | `true` |
   | `mke_external_ca_src` | path to `ca.pem` on the Ansible controller, or the literal PEM content |
   | `mke_external_cert_src` | path to `cert.pem`, or the literal PEM content |
   | `mke_external_key_src` | path to `key.pem`, or the literal PEM content |

   Each `*_src` var accepts either a file path on the Ansible controller or
   the literal PEM content itself (same convention as `mke_config_src` — see
   the [install runbook's F.A.Q](install-bootc-mke3.md#faq)). A single
   shared cert/key is copied to every manager node; MKE auto-propagates it
   to managers that join or get promoted later.

2. Run the installer as normal:

   ```bash
   cd ansible
   ansible-playbook -i <path-to-your-inventory> mke-install-playbook.yml
   ```

   Before MKE install runs, `tasks/mke-external-certs-tasks.yml` creates the
   `ucp-controller-server-certs` Docker volume on every manager and writes
   your `ca.pem`/`cert.pem`/`key.pem` into it; `tasks/mke-install-tasks.yml`
   then appends `--external-server-cert` to the `mke install` command so MKE
   picks up the supplied bundle instead of generating its own.

## Expected Results

- `https://<mke_url>` presents your certificate chain, not MKE's self-signed
  default:

  ```bash
  echo | openssl s_client -connect <mke_url>:443 -showcerts 2>/dev/null | openssl x509 -noout -issuer -subject
  ```

- Browsers and API clients that already trust your CA no longer show a
  certificate warning when accessing the MKE web UI.

## F.A.Q

### Can I rotate the certificate on an already-installed cluster?

Not through this playbook. Mirantis's own MKE 3.9 documentation only
describes a live-rotation path through the MKE web UI (**\<user name\> →
Admin Settings → Certificates** → upload key/cert/CA → **Save**) — no
CLI/API equivalent is documented. Use the web UI for a live rotation, or set
`mke_external_certs_enabled` and reprovision for a fresh install.

### Can different managers use different certificates?

Not with this integration as implemented — `tasks/mke-external-certs-tasks.yml`
copies one shared bundle to every manager. MKE itself does support per-node
certificates that share a common SAN (see the upstream reference below), but
automating that would require per-host variables; this repo doesn't do that
today.

### Does this also replace MKE's internal CAs?

No. See [Replace MKE root CA material](../operations-guide/replace-mke-root-ca.md)
for the separate, standalone playbook that replaces MKE's internal
Cluster/etcd/Client root CAs.

## References

- [Use an External Certificate Authority](https://docs.mirantis.com/mke/3.9/install/predeployment/use-ext-ca.html)
- [`install` CLI reference](https://docs.mirantis.com/mke/3.9/cli-ref/mke-cli-install.html)
- [Use your own TLS certificates (post-install/UI path)](https://docs.mirantis.com/mke/3.9/ops/administer-cluster/use-your-own-tls-certificates.html)
- [Add SANs to cluster certificates](https://docs.mirantis.com/mke/3.9/ops/administer-cluster/add-sans-to-cluster-certs.html)
