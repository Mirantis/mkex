locals {
  # All the IP calculations are basically just conversion of IP address to decimal representation,
  # calculate IP addresses in range (by incrementation of decimal value) and convert back to string

  managers_start_ip         = split("-", var.ip_range_managers)[0]
  managers_end_ip           = split("-", var.ip_range_managers)[1]
  workers_start_ip          = split("-", var.ip_range_workers)[0]
  workers_end_ip            = split("-", var.ip_range_workers)[1]

  managers_start_decimal    = (tonumber(split(".", local.managers_start_ip)[0]) * 256 * 256 * 256 +
                              tonumber(split(".", local.managers_start_ip)[1]) * 256 * 256 +
                              tonumber(split(".", local.managers_start_ip)[2]) * 256 +
                              tonumber(split(".", local.managers_start_ip)[3]))
  managers_end_decimal      = (tonumber(split(".", local.managers_end_ip)[0]) * 256 * 256 * 256 +
                              tonumber(split(".", local.managers_end_ip)[1]) * 256 * 256 +
                              tonumber(split(".", local.managers_end_ip)[2]) * 256 +
                              tonumber(split(".", local.managers_end_ip)[3]))
  workers_start_decimal     = (tonumber(split(".", local.workers_start_ip)[0]) * 256 * 256 * 256 +
                              tonumber(split(".", local.workers_start_ip)[1]) * 256 * 256 +
                              tonumber(split(".", local.workers_start_ip)[2]) * 256 +
                              tonumber(split(".", local.workers_start_ip)[3]))
  workers_end_decimal       = (tonumber(split(".", local.workers_end_ip)[0]) * 256 * 256 * 256 +
                              tonumber(split(".", local.workers_end_ip)[1]) * 256 * 256 +
                              tonumber(split(".", local.workers_end_ip)[2]) * 256 +
                              tonumber(split(".", local.workers_end_ip)[3]))

  managers_ips              = [for i in range(local.managers_end_decimal - local.managers_start_decimal + 1) : 
                                join(
                                  ".",
                                  [
                                    floor((local.managers_start_decimal + i) / (256 * 256 * 256)) % 256,
                                    floor((local.managers_start_decimal + i) / (256 * 256)) % 256,
                                    floor((local.managers_start_decimal + i) / 256) % 256,
                                    (local.managers_start_decimal + i) % 256
                                  ]
                                ) 
                              ]
  workers_ips              = [for i in range(local.workers_end_decimal - local.workers_start_decimal + 1) : 
                                join(
                                  ".",
                                  [
                                    floor((local.workers_start_decimal + i) / (256 * 256 * 256)) % 256,
                                    floor((local.workers_start_decimal + i) / (256 * 256)) % 256,
                                    floor((local.workers_start_decimal + i) / 256) % 256,
                                    (local.workers_start_decimal + i) % 256
                                  ]
                                ) 
                              ]

  managers_hostnames        = [for i in range(var.quantity_managers) : "${var.cluster_name}-mngr${(i+1)}"]
  workers_hostnames         = [for i in range(var.quantity_workers) : "${var.cluster_name}-wrk${(i+1)}"]
  
}

module "managers" {
  source               = "./modules/virtual_machine"
  count                = var.quantity_managers
  hostname             = local.managers_hostnames[count.index]
  resource_pool_id     = data.vsphere_resource_pool.resource_pool.id
  datastore_id         = var.datastore == null ? null : data.vsphere_datastore.datastore[0].id
  datastore_cluster_id = var.datastore_cluster == null ? null: data.vsphere_datastore_cluster.datastore_cluster[0].id
  folder               = var.folder
  network_id           = data.vsphere_network.network.id
  template_vm          = data.vsphere_virtual_machine.manager_vm_template
  disk_size            = var.manager_disk_size
  vm_user              = var.vm_user
  cpu_count            = var.cpu_count_managers
  memory_count         = var.memory_count_managers
  firmware             = var.firmware
  user_data            = base64encode(
                           templatefile(
                             "${path.module}/helpers/cloudinit/userdata-mngr.yaml", 
                             {
                               ssh_key = file(var.ssh_public_key_file), 
                               hostname = local.managers_hostnames[count.index], 
                               user = var.vm_user
                             }
                           )
                         )
  meta_data            = var.network_type == "IPAM" ? base64encode(
                           templatefile(
                             "${path.module}/helpers/cloudinit/metadata-ipam.yaml",
                             { 
                               ip_addr = local.managers_ips[count.index], 
                               gateway_addr = var.network_gateway, 
                               hostname = local.managers_hostnames[count.index], 
                               nameserver = var.nameserver 
                             }
                           )
                         ) : base64encode(
                           templatefile(
                             "${path.module}/helpers/cloudinit/metadata-dhcp.yaml",
                             { 
                               hostname = local.managers_hostnames[count.index], 
                             }
                           )
                         )
}

module "workers" {
  source               = "./modules/virtual_machine"
  count                = var.quantity_workers
  hostname             = local.workers_hostnames[count.index]
  resource_pool_id     = data.vsphere_resource_pool.resource_pool.id
  datastore_id         = var.datastore == null ? null : data.vsphere_datastore.datastore[0].id
  datastore_cluster_id = var.datastore_cluster == null ? null: data.vsphere_datastore_cluster.datastore_cluster[0].id
  folder               = var.folder
  network_id           = data.vsphere_network.network.id
  template_vm          = data.vsphere_virtual_machine.worker_vm_template
  disk_size            = var.worker_disk_size
  vm_user              = var.vm_user
  cpu_count            = var.cpu_count_workers
  memory_count         = var.memory_count_workers
  firmware             = var.firmware
  user_data            = base64encode(
                           templatefile(
                             "${path.module}/helpers/cloudinit/userdata-wrk.yaml",
                             { 
                               ssh_key = file(var.ssh_public_key_file), 
                               hostname = local.workers_hostnames[count.index], 
                               user = var.vm_user
                             }
                           )
                         )
  meta_data            = var.network_type == "IPAM" ? base64encode(
                           templatefile(
                             "${path.module}/helpers/cloudinit/metadata-ipam.yaml",
                             { 
                               ip_addr = local.workers_ips[count.index], 
                               gateway_addr = var.network_gateway, 
                               hostname = local.workers_hostnames[count.index], 
                               nameserver = var.nameserver 
                             }
                           )
                         ) : base64encode(
                           templatefile(
                             "${path.module}/helpers/cloudinit/metadata-dhcp.yaml",
                             { 
                               hostname = local.workers_hostnames[count.index], 
                             }
                           )
                         )
}
