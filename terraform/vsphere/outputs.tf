locals {
  ansible_inventory = <<-EOT

all:
  hosts:
  %{~for manager in module.managers}
      # ${manager.vm_name}
      ${manager.vm_name}:
          ansible_connection: ssh
          ansible_ssh_private_key_file: ${var.ssh_private_key_file}
          ansible_user: ${var.vm_user}
          ansible_host: ${manager.ip_address}
  %{~endfor~}
  %{~if var.quantity_workers != 0}
  %{~for worker in module.workers}
      # ${worker.vm_name}
      ${worker.vm_name}:
          ansible_connection: ssh
          ansible_ssh_private_key_file: ${var.ssh_private_key_file}
          ansible_user: ${var.vm_user}
          ansible_host: ${worker.ip_address}
  %{~endfor~}
  %{~endif~}
  children:
    managers:
      hosts:
      %{~for manager in module.managers}
          ${manager.vm_name}:
      %{~endfor~}
    workers:
      hosts:
      %{~if var.quantity_workers != 0}
      %{~for worker in module.workers}
          ${worker.vm_name}:
      %{~endfor~}
      %{~endif~}
  vars:
    mke_url: ${module.managers[0].ip_address}
EOT
}

output "ansible_inventory" {
  value = local.ansible_inventory
  #  value = yamlencode(local.ansible_inventory)
}
