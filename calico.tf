#############################################
# Calico CNI, applied once the cluster and all nodes are up
#############################################

resource "null_resource" "install_calico" {
  count = var.install_calico ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
  ]

  triggers = {
    control_plane_id = proxmox_virtual_environment_vm.control_plane[0].id
    pod_cidr         = var.pod_network_cidr
    calico_version   = var.calico_version
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # ipPools.cidr is rendered from the same var.pod_network_cidr used in
  # kubeadm-config.yaml.tpl, so the two can never drift apart.
  provisioner "file" {
    content     = local.calico_custom_resources
    destination = "/tmp/calico-custom-resources.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "curl -sL https://raw.githubusercontent.com/projectcalico/calico/${var.calico_version}/manifests/v1_crd_projectcalico_org.yaml -o /tmp/calico-crds.yaml",
      "kubectl apply --server-side --force-conflicts -f /tmp/calico-crds.yaml",
      "curl -sL https://raw.githubusercontent.com/projectcalico/calico/${var.calico_version}/manifests/tigera-operator.yaml -o /tmp/tigera-operator.yaml",
      "kubectl apply --server-side --force-conflicts -f /tmp/tigera-operator.yaml",
      "kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=300s",
      "kubectl apply -f /tmp/calico-custom-resources.yaml",
      "kubectl wait tigerastatus/calico --for=create --timeout=300s",
      "kubectl wait tigerastatus/calico --for=condition=Available --timeout=600s",
    ]
  }
}
