#############################################
# Format and mount each worker's data disk (for Longhorn or similar)
#############################################

resource "null_resource" "prepare_worker_data_disk" {
  count = var.prepare_worker_data_disk ? var.worker_count : 0

  triggers = {
    worker_id   = proxmox_virtual_environment_vm.worker[count.index].id
    device       = var.worker_data_disk_device
    filesystem    = var.worker_data_disk_filesystem
    mount_point   = var.worker_data_disk_mount_point
  }

  connection {
    type        = "ssh"
    host        = local.worker_ips[count.index]
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      # Only format if the disk has no existing filesystem -- never touch
      # a disk that already has real data on it (e.g. re-applying against
      # a worker that's already running Longhorn).
      "if ! sudo blkid ${var.worker_data_disk_device} >/dev/null 2>&1; then sudo mkfs.${var.worker_data_disk_filesystem} -F ${var.worker_data_disk_device}; fi",
      "sudo mkdir -p ${var.worker_data_disk_mount_point}",
      "UUID=$(sudo blkid -s UUID -o value ${var.worker_data_disk_device})",
      "grep -q \"$UUID\" /etc/fstab || echo \"UUID=$UUID ${var.worker_data_disk_mount_point} ${var.worker_data_disk_filesystem} defaults,nofail 0 2\" | sudo tee -a /etc/fstab",
      "sudo systemctl daemon-reload",
      "sudo mount -a",
      # Fail loudly if it isn't actually mounted, rather than silently
      # leaving Longhorn to write onto the root filesystem instead.
      "mountpoint -q ${var.worker_data_disk_mount_point}",
    ]
  }
}
