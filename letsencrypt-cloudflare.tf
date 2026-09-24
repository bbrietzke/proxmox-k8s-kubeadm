#############################################
# Let's Encrypt ClusterIssuers (staging + production), Cloudflare DNS-01
#############################################

resource "null_resource" "install_letsencrypt_cloudflare_issuers" {
  count = var.install_letsencrypt_cloudflare_issuers ? 1 : 0

  depends_on = [
    null_resource.kubeadm_init,
    null_resource.control_plane_join,
    null_resource.worker_join,
    null_resource.install_calico,
    null_resource.install_cert_manager,
  ]

  triggers = {
    control_plane_id    = proxmox_virtual_environment_vm.control_plane[0].id
    acme_email            = var.acme_email
    cloudflare_api_token   = var.cloudflare_api_token
    cloudflare_secret_name = var.cloudflare_secret_name
    cert_manager_namespace = var.cert_manager_namespace
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.cloudflare_secret_manifest
    destination = "/tmp/cloudflare-api-token-secret.yaml"
  }

  provisioner "file" {
    content     = local.cluster_issuers_manifest
    destination = "/tmp/letsencrypt-cluster-issuers.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "kubectl apply -f /tmp/cloudflare-api-token-secret.yaml",
      # Don't leave the plaintext token sitting in /tmp longer than it has to.
      "rm -f /tmp/cloudflare-api-token-secret.yaml",
      "kubectl apply -f /tmp/letsencrypt-cluster-issuers.yaml",
      # Ready here means the ACME account registered successfully against
      # each server -- it doesn't prove a DNS-01 challenge will succeed,
      # since that only happens once a real Certificate is requested.
      "kubectl wait --for=condition=Ready clusterissuer/letsencrypt-staging --timeout=120s",
      "kubectl wait --for=condition=Ready clusterissuer/letsencrypt-production --timeout=120s",
    ]
  }
}
