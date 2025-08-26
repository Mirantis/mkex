resource "vsphere_virtual_machine" "vm" {
  name             = var.hostname 
  resource_pool_id = var.resource_pool_id
  datastore_id     = var.datastore_id == null ? null : var.datastore_id
  datastore_cluster_id     = var.datastore_cluster_id == null ? null : var.datastore_cluster_id
  firmware         = var.firmware 
  folder           = var.folder

  guest_id = var.template_vm.guest_id

  network_interface {
    network_id = var.network_id
  }

  cdrom {
    client_device = true
  }

  num_cpus = var.cpu_count

  memory = var.memory_count

  enable_disk_uuid = true # NB the VM must have disk.EnableUUID=1 for, e.g., k8s persistent storage.

  disk {
    label            = var.hostname 
    size             = var.disk_size
    thin_provisioned = var.template_vm.disks.0.thin_provisioned
  }

  clone {
    template_uuid = var.template_vm.id
  }

  extra_config = {
    "guestinfo.userdata" = var.user_data
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata" = var.meta_data
    "guestinfo.metadata.encoding" = "base64"
  }
}
