#############################################
# kube-prometheus-stack, applied once Calico (and Longhorn, if enabled) is up
#############################################

resource "null_resource" "install_prometheus" {
  count = var.install_prometheus ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
    null_resource.install_longhorn,
  ]

  triggers = {
    control_plane_id        = proxmox_virtual_environment_vm.control_plane[0].id
    prometheus_chart_version  = var.prometheus_chart_version
    helm_version               = var.helm_version
    prometheus_extra_values    = var.prometheus_extra_values
    use_persistence             = local.prometheus_use_persistence
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # storage/retention/admin-password rendered here from named variables;
  # anything else goes in prometheus_extra_values below.
  provisioner "file" {
    content     = local.prometheus_values
    destination = "/tmp/prometheus-values.yaml"
  }

  provisioner "file" {
    content     = var.prometheus_extra_values
    destination = "/tmp/prometheus-extra-values.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "which helm >/dev/null 2>&1 || (curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x /tmp/get_helm.sh && sudo /tmp/get_helm.sh --version ${var.helm_version})",
      "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
      "helm repo update",
      # Retried for the same reason as the other charts' installs --
      # transient apiserver/etcd load from concurrent addon installs, not
      # a real failure. Safe to retry.
      "i=0; until helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version ${var.prometheus_chart_version} --namespace ${var.prometheus_namespace} --create-namespace -f /tmp/prometheus-values.yaml -f /tmp/prometheus-extra-values.yaml; do i=$((i+1)); if [ \"$i\" -ge 3 ]; then echo 'helm upgrade --install prometheus failed after 3 attempts' >&2; exit 1; fi; sleep 15; done",
      "kubectl -n ${var.prometheus_namespace} rollout status deployment/prometheus-kube-prometheus-operator --timeout=300s",
      "kubectl -n ${var.prometheus_namespace} rollout status deployment/prometheus-grafana --timeout=300s",
    ]
  }
}
