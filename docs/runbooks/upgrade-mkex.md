# Upgrade MKEx

This guide explains how to upgrade an existing **Mirantis Kubernetes Engine (MKE)** cluster to the latest version or switch to a specific newer release.

## Prerequisites

- **Ansible** installed on the machine running the upgrade.  
- An **Ansible inventory** describing the cluster.  
  - See the [inventory description document](../ansible-inventory-input.md) for details.

## Upgrade Steps

1. **Upgrade to the latest version of the current image tag**  
   Leave `bootc_image_ref` unchanged or empty in `upgrade-vars.yaml`.

   **Switch to a newer version**  
   Update `bootc_image_ref` in `upgrade-vars.yaml` with the full OCI image URL, including the image tag.

2. **Override defaults (optional)**  
   Add custom values in:
   - `vars/common-vars.yml`  
   - `vars/mke-creds.yml`

3. **Confirm the inventory**  
   Ensure the expected Ansible inventory file exists and is correct.

4. **Run the upgrade**  
   ```bash
   ansible-playbook -i <path-to-your-inventory> ansible/mke-upgrade-playbook.yml

## Expected Results

Ansible playbook runs without error. In order to verify the upgrade, go to the MKE UI (`mke_url` in ansible inventory file) and log in with the credentials specified in `vars/mke-creds.yml` and make sure version is upgraded as expected.

