#############################################
# prometheus-adapter, serving metrics.k8s.io from Prometheus's own data
#############################################

resource "null_resource" "install_prometheus_adapter" {
  count = var.install_prometheus_adapter ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
    null_resource.install_prometheus,
  ]

  triggers = {
    control_plane_id                = proxmox_virtual_environment_vm.control_plane[0].id
    prometheus_adapter_chart_version  = var.prometheus_adapter_chart_version
    helm_version                       = var.helm_version
    prometheus_adapter_extra_values    = var.prometheus_adapter_extra_values
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    content     = var.prometheus_adapter_extra_values
    destination = "/tmp/prometheus-adapter-extra-values.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "which helm >/dev/null 2>&1 || (curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x /tmp/get_helm.sh && sudo /tmp/get_helm.sh --version ${var.helm_version})",
      "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
      "helm repo update",
      # Points at the Prometheus Service this project's own kube-prometheus-stack
      # install creates (release name "prometheus" -> service
      # prometheus-kube-prometheus-prometheus). rules.default (chart
      # default: true) is enough on its own to serve CPU/memory via
      # metrics.k8s.io -- no custom PromQL required for the basic case.
      "i=0; until helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter --version ${var.prometheus_adapter_chart_version} --namespace ${var.prometheus_namespace} --create-namespace --set prometheus.url=http://prometheus-kube-prometheus-prometheus.${var.prometheus_namespace}.svc --set prometheus.port=9090 -f /tmp/prometheus-adapter-extra-values.yaml; do i=$((i+1)); if [ \"$i\" -ge 3 ]; then echo 'helm upgrade --install prometheus-adapter failed after 3 attempts' >&2; exit 1; fi; sleep 15; done",
      "kubectl -n ${var.prometheus_namespace} rollout status deployment/prometheus-adapter --timeout=300s",
      # Functional check, not just a rollout check: confirm metrics.k8s.io
      # is actually serving data, not merely that the pod is Running. The
      # adapter needs at least one relist interval (chart default 1m)
      # after starting before it has anything to report.
      "i=0; until kubectl top nodes >/dev/null 2>&1; do i=$((i+1)); if [ \"$i\" -ge 12 ]; then echo 'kubectl top nodes still failing after prometheus-adapter install' >&2; exit 1; fi; sleep 10; done",
    ]
  }
}
