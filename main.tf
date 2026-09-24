#############################################
# Control plane node(s)
#############################################

resource "proxmox_virtual_environment_vm" "control_plane" {
  count = local.control_plane_count

  vm_id     = local.control_plane_vmids[count.index]
  name      = local.control_plane_names[count.index]
  node_name = local.control_plane_placement[count.index]
  migrate   = true

  timeout_migrate = var.vm_migrate_timeout

  clone {
    vm_id     = var.template_vm_id
    node_name = var.template_node
    full      = true
  }

  cpu {
    cores = var.control_plane_cores
    type  = "host"
  }

  memory {
    dedicated = var.control_plane_memory
  }

  agent {
    enabled = true
  }

  # Resize the cloned boot disk. Interface must match the template's boot disk interface.
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.control_plane_boot_disk_size
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.vlan_id
  }

  initialization {
    datastore_id = var.datastore_id

    user_account {
      username = var.ci_username
      password = var.ci_password
      keys     = var.ssh_public_keys
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      clone,
    ]
  }
}

#############################################
# Worker nodes
#############################################

resource "proxmox_virtual_environment_vm" "worker" {
  count = var.worker_count

  # Wait for every control-plane VM to exist before creating any worker.
  # This is a plain cross-resource dependency (control_plane and worker
  # are separate resource blocks), not the same self-referencing pattern
  # that Terraform disallows for ordering instances within one resource --
  # so it's fully supported, unlike a per-instance one-at-a-time chain
  # would be.
  depends_on = [proxmox_virtual_environment_vm.control_plane]

  vm_id     = local.worker_vmids[count.index]
  name      = local.worker_names[count.index]
  node_name = local.worker_placement[count.index]
  migrate   = true

  timeout_migrate = var.vm_migrate_timeout

  clone {
    vm_id     = var.template_vm_id
    node_name = var.template_node
    full      = true
  }

  cpu {
    cores = var.worker_cores
    type  = "host"
  }

  memory {
    dedicated = var.worker_memory
  }

  agent {
    enabled = true
  }

  # Boot disk, resized from the clone
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.worker_boot_disk_size
  }

  # Second, independent data disk sized by var.worker_data_disk_size (default 256 GB)
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = var.worker_data_disk_size
    file_format  = "raw"
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.vlan_id
  }

  initialization {
    datastore_id = var.datastore_id

    user_account {
      username = var.ci_username
      password = var.ci_password
      keys     = var.ssh_public_keys
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      clone,
    ]
  }
}
