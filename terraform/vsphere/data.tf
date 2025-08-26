data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_resource_pool" "resource_pool" {
  name          = var.resource_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  count = var.datastore == null && var.datastore_cluster != null ? 0 : 1

  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore_cluster" "datastore_cluster" {
  count = var.datastore_cluster == null && var.datastore != null ? 0 : 1

  name          = var.datastore_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "manager_vm_template" {
  name          = var.manager_vm_template
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "worker_vm_template" {
  name          = var.worker_vm_template
  datacenter_id = data.vsphere_datacenter.dc.id
}

