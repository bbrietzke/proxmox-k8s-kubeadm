#############################################
# MetalLB (Layer2/ARP LoadBalancer provisioner), applied once Calico is up
#############################################

resource "null_resource" "install_metallb" {
  count = var.install_metallb ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
  ]

  triggers = {
    control_plane_id = proxmox_virtual_environment_vm.control_plane[0].id
    metallb_version   = var.metallb_version
    address_pool      = join(",", var.metallb_address_pool)
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.metallb_config
    destination = "/tmp/metallb-config.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "curl -sL https://raw.githubusercontent.com/metallb/metallb/${var.metallb_version}/config/manifests/metallb-native.yaml -o /tmp/metallb-native.yaml",
      "kubectl apply -f /tmp/metallb-native.yaml",
      "kubectl wait --for=condition=Available deployment/controller -n metallb-system --timeout=300s",
      # The validating webhook can take a few seconds to come up after the
      # controller reports Available, so the first apply of the address
      # pool sometimes gets rejected -- retry, but still fail the script
      # (and thus this resource) if it never succeeds.
      "i=0; until kubectl apply -f /tmp/metallb-config.yaml; do i=$((i+1)); if [ \"$i\" -ge 12 ]; then echo 'metallb-config apply failed after 12 attempts' >&2; exit 1; fi; sleep 5; done",
    ]
  }
}
