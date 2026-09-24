#############################################
# cert-manager, applied once Calico is up
#############################################

resource "null_resource" "install_cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
  ]

  triggers = {
    control_plane_id          = proxmox_virtual_environment_vm.control_plane[0].id
    cert_manager_version       = var.cert_manager_version
    helm_version                = var.helm_version
    cert_manager_extra_values   = var.cert_manager_extra_values
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # Anything not covered by --set crds.enabled=true below goes here (see
  # cert_manager_extra_values); pushed even when empty so the -f flag is
  # always valid.
  provisioner "file" {
    content     = var.cert_manager_extra_values
    destination = "/tmp/cert-manager-extra-values.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "which helm >/dev/null 2>&1 || (curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x /tmp/get_helm.sh && sudo /tmp/get_helm.sh --version ${var.helm_version})",
      "helm repo add jetstack https://charts.jetstack.io --force-update",
      "helm repo update",
      # Retried: a transient apiserver/etcd hiccup (e.g. several addons'
      # installs landing in the same narrow window) can make a single
      # 'helm install' attempt fail even though the cluster is otherwise
      # healthy. Safe to retry -- helm upgrade --install reconciles from
      # wherever a partial attempt left off rather than starting over
      # destructively.
      "i=0; until helm upgrade --install cert-manager jetstack/cert-manager --version ${var.cert_manager_version} --namespace ${var.cert_manager_namespace} --create-namespace --set crds.enabled=true -f /tmp/cert-manager-extra-values.yaml; do i=$((i+1)); if [ \"$i\" -ge 3 ]; then echo 'helm upgrade --install cert-manager failed after 3 attempts' >&2; exit 1; fi; sleep 15; done",
      "kubectl wait --for=condition=Available deployment/cert-manager -n ${var.cert_manager_namespace} --timeout=300s",
      "kubectl wait --for=condition=Available deployment/cert-manager-webhook -n ${var.cert_manager_namespace} --timeout=300s",
    ]
  }
}
