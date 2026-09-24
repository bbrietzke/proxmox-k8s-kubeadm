output "cluster_name" {
  description = "Cluster name passed to kubeadm"
  value       = var.cluster_name
}

output "control_plane_ips" {
  description = "IP addresses of all control plane nodes"
  value       = local.control_plane_ips
}

output "control_plane_vmids" {
  description = "VMIDs assigned to control plane nodes"
  value       = local.control_plane_vmids
}

output "worker_ips" {
  description = "IP addresses of the worker nodes"
  value       = local.worker_ips
}

output "worker_vmids" {
  description = "VMIDs assigned to worker nodes"
  value       = local.worker_vmids
}

output "control_plane_endpoint" {
  description = "The controlPlaneEndpoint kubeadm was configured with"
  value       = local.control_plane_endpoint
}

output "kube_vip_enabled" {
  description = "Whether kube-vip was configured (control_plane_vip was set)"
  value       = local.use_kube_vip
}

output "calico_installed" {
  description = "Whether this project installed Calico as the CNI (install_calico)"
  value       = var.install_calico
}

output "metallb_installed" {
  description = "Whether this project installed MetalLB as the LoadBalancer provisioner (install_metallb)"
  value       = var.install_metallb
}

output "traefik_installed" {
  description = "Whether this project installed Traefik as the ingress controller (install_traefik)"
  value       = var.install_traefik
}

output "cert_manager_installed" {
  description = "Whether this project installed cert-manager (install_cert_manager). No ClusterIssuer is created -- that's a separate step."
  value       = var.install_cert_manager
}

output "letsencrypt_cloudflare_issuers_installed" {
  description = "Whether the letsencrypt-staging / letsencrypt-production ClusterIssuers were created (install_letsencrypt_cloudflare_issuers)"
  value       = var.install_letsencrypt_cloudflare_issuers
}

output "node_labels_applied" {
  description = "The full set of node labels actually applied (automatic zone labels merged with node_labels)"
  value       = local.effective_node_labels
}

output "control_plane_placement" {
  description = "Which Proxmox node each control-plane instance actually landed on, by index"
  value       = local.control_plane_placement
}

output "worker_placement" {
  description = "Which Proxmox node each worker instance actually landed on, by index"
  value       = local.worker_placement
}

output "worker_data_disk_mount_point" {
  description = "Where the worker data disk was mounted, if prepare_worker_data_disk = true"
  value       = var.prepare_worker_data_disk ? var.worker_data_disk_mount_point : null
}

output "longhorn_installed" {
  description = "Whether this project installed Longhorn (install_longhorn), and the replica count it was configured with"
  value       = var.install_longhorn ? "installed, replica count ${local.longhorn_replica_count}" : "not installed"
}

output "prometheus_installed" {
  description = "Whether this project installed kube-prometheus-stack (install_prometheus), and whether it's using persistent storage"
  value       = var.install_prometheus ? "installed, persistence ${local.prometheus_use_persistence}" : "not installed"
}

output "metrics_server_replacement" {
  description = "Whether prometheus-adapter is serving metrics.k8s.io (kubectl top / HPA) in place of a standalone metrics-server"
  value       = var.install_prometheus_adapter
}

output "worker_join_command" {
  description = "The kubeadm join command run on each worker"
  value       = trimspace(data.local_file.worker_join_command.content)
}

output "control_plane_join_commands" {
  description = "The fresh kubeadm join commands used for each additional control-plane node (only meaningful when control_plane_ha = true) -- one per extra control plane, regenerated just before use each time, so this only reflects the most recent apply's values"
  value       = [for f in data.local_file.control_plane_join_command_fresh : trimspace(f.content)]
}

output "kubeconfig_path" {
  description = "Local path to the fetched kubeconfig for this cluster"
  value       = "${path.module}/generated/kubeconfig"
  depends_on  = [null_resource.fetch_kubeconfig]
}
