# MKEx

MKEx is an integrated container orchestration platform that is powered by an immutable Rocky Linux operating system, offering next-level security and reliability.

This repository contains a collection of tool, utilities and guides for managing and operating with MKEx. These tools support operations, automation, and configuration for secure and scalable container environments.

## Provisioning

Provisioning is the process of preparing a cluster of MKEx compute nodes within a network environment that meets the requirements for deploying and operating Mirantis products.

For further details, please see [provisioning document](docs/provisioning.md).

## Installation

Installation in this document refers to the process of deploying Mirantis Kubernetes Engine on top of already provisioned machines (VMs or baremetal). 

To perform installation, [Ansible](https://docs.ansible.com/) is used. There are number of tasks and the playbook that serves this purpose.

Prerequisites for the installation can be found in the [Provisioning](#provisioning) section of this document.

To perform the installation, please see [installation runbook](docs/runbooks/install-mkex.md).

## Troubleshooting

If you encounter issues, file an issue, or talk to us on the #prod-eng or #mkex-internal channel on the Mirantis Slack server.
