#############################################
# Traefik ingress controller, applied once Calico is up
#############################################

resource "null_resource" "install_traefik" {
  count = var.install_traefik ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
    null_resource.install_metallb,
  ]

  triggers = {
    control_plane_id           = proxmox_virtual_environment_vm.control_plane[0].id
    traefik_chart_version      = var.traefik_chart_version
    helm_version                = var.helm_version
    traefik_enable_gateway_api = tostring(var.traefik_enable_gateway_api)
    gateway_api_version         = var.gateway_api_version
    traefik_enable_ingress      = tostring(var.traefik_enable_ingress)
    traefik_extra_values        = var.traefik_extra_values
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.traefik_values
    destination = "/tmp/traefik-values.yaml"
  }

  # Anything not covered by the named variables goes here (see
  # traefik_extra_values); pushed even when empty so the -f flag below is
  # always valid -- an empty file is a no-op override.
  provisioner "file" {
    content     = var.traefik_extra_values
    destination = "/tmp/traefik-extra-values.yaml"
  }

  provisioner "remote-exec" {
    inline = concat(
      ["set -euo pipefail"],
      var.traefik_enable_gateway_api ? [
        # The Traefik chart no longer bundles Gateway API CRDs -- install
        # them ourselves first, or providers.kubernetesGateway.enabled
        # fails outright with "no matches for kind Gateway/HTTPRoute/...".
        "curl -sL https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml -o /tmp/gateway-api-crds.yaml",
        "kubectl apply --server-side --force-conflicts -f /tmp/gateway-api-crds.yaml",
      ] : [],
      [
        "which helm >/dev/null 2>&1 || (curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x /tmp/get_helm.sh && sudo /tmp/get_helm.sh --version ${var.helm_version})",
        "helm repo add traefik https://traefik.github.io/charts",
        "helm repo update",
        # Retried for the same reason as cert-manager's install -- transient
        # apiserver/etcd load from concurrent addon installs, not a real
        # failure. Safe to retry.
        "i=0; until helm upgrade --install traefik traefik/traefik --version ${var.traefik_chart_version} --namespace ${var.traefik_namespace} --create-namespace -f /tmp/traefik-values.yaml -f /tmp/traefik-extra-values.yaml; do i=$((i+1)); if [ \"$i\" -ge 3 ]; then echo 'helm upgrade --install traefik failed after 3 attempts' >&2; exit 1; fi; sleep 15; done",
        "kubectl rollout status deployment/traefik -n ${var.traefik_namespace} --timeout=300s",
      ]
    )
  }
}
