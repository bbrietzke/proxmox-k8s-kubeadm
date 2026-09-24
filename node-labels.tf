#############################################
# Node labels, applied once every node has joined
#############################################

resource "null_resource" "label_nodes" {
  count = length(local.effective_node_labels) > 0 ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
  ]

  triggers = {
    control_plane_id = proxmox_virtual_environment_vm.control_plane[0].id
    node_labels        = jsonencode(local.effective_node_labels)
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = concat(
      ["set -euo pipefail"],
      local.node_label_commands
    )
  }
}
