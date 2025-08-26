output "vm_name" {
  value = vsphere_virtual_machine.vm.name
}

output "ip_address" {
  value = vsphere_virtual_machine.vm.default_ip_address
}
