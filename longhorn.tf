#############################################
# Longhorn prerequisites on each worker (open-iscsi, nfs client)
#############################################

resource "null_resource" "longhorn_prereqs" {
  count = var.install_longhorn ? var.worker_count : 0

  triggers = {
    worker_id = proxmox_virtual_environment_vm.worker[count.index].id
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
      # Longhorn's engine pods need iscsiadm on the host or they crashloop.
      # nfs-common/nfs-utils enables Longhorn's built-in RWX (NFS) support.
      # Package names differ across distro families, so detect and use
      # whichever package manager is actually present on the template.
      "if command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y open-iscsi nfs-common; elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y iscsi-initiator-utils nfs-utils; elif command -v yum >/dev/null 2>&1; then sudo yum install -y iscsi-initiator-utils nfs-utils; else echo 'No supported package manager (apt-get/dnf/yum) found -- install open-iscsi/nfs-common equivalents manually' >&2; exit 1; fi",
      "sudo systemctl enable --now iscsid",
    ]
  }
}

#############################################
# Longhorn itself, applied once Calico and the prereqs above are ready
#############################################

resource "null_resource" "install_longhorn" {
  count = var.install_longhorn ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
    null_resource.prepare_worker_data_disk,
    null_resource.longhorn_prereqs,
  ]

  triggers = {
    control_plane_id        = proxmox_virtual_environment_vm.control_plane[0].id
    longhorn_version          = var.longhorn_version
    helm_version                = var.helm_version
    longhorn_replica_count     = local.longhorn_replica_count
    longhorn_extra_values      = var.longhorn_extra_values
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # Anything not covered by the replica-count --set flags below goes here
  # (see longhorn_extra_values); pushed even when empty so the -f flag is
  # always valid.
  provisioner "file" {
    content     = var.longhorn_extra_values
    destination = "/tmp/longhorn-extra-values.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "which helm >/dev/null 2>&1 || (curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x /tmp/get_helm.sh && sudo /tmp/get_helm.sh --version ${var.helm_version})",
      "helm repo add longhorn https://charts.longhorn.io",
      "helm repo update",
      # Retried for the same reason as cert-manager's install -- transient
      # apiserver/etcd load from concurrent addon installs, not a real
      # failure. Safe to retry.
      "i=0; until helm upgrade --install longhorn longhorn/longhorn --version ${var.longhorn_version} --namespace ${var.longhorn_namespace} --create-namespace --set defaultSettings.defaultReplicaCount=${local.longhorn_replica_count} --set persistence.defaultClassReplicaCount=${local.longhorn_replica_count} -f /tmp/longhorn-extra-values.yaml; do i=$((i+1)); if [ \"$i\" -ge 3 ]; then echo 'helm upgrade --install longhorn failed after 3 attempts' >&2; exit 1; fi; sleep 15; done",
      "kubectl -n ${var.longhorn_namespace} rollout status daemonset/longhorn-manager --timeout=600s",
      "kubectl -n ${var.longhorn_namespace} rollout status deployment/longhorn-driver-deployer --timeout=300s",
    ]
  }
}
