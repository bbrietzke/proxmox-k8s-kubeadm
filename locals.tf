locals {
  control_plane_node = coalesce(var.control_plane_node, var.proxmox_node)
  worker_node         = coalesce(var.worker_node, var.proxmox_node)

  control_plane_count = var.control_plane_ha ? 3 : 1

  # Per-instance placement: an override in control_plane_nodes/worker_nodes
  # wins for that index; everything else falls back to the single default
  # above. This is a per-index lookup layered on top of `count`, not a
  # switch to `for_each` -- so an override only ever shows as an in-place
  # `~` diff on that one instance's node_name (handled by migrate = true),
  # never a resource address change that would force a replace.
  control_plane_placement = [
    for i in range(local.control_plane_count) :
    try(var.control_plane_nodes[tostring(i)].placement_zone, null) != null
    ? var.control_plane_nodes[tostring(i)].placement_zone
    : local.control_plane_node
  ]
  worker_placement = [
    for i in range(var.worker_count) :
    try(var.worker_nodes[tostring(i)].placement_zone, null) != null
    ? var.worker_nodes[tostring(i)].placement_zone
    : local.worker_node
  ]

  # Control-plane nodes take starting_vmid..starting_vmid+N-1; workers continue
  # upward from wherever the control-plane range ends.
  control_plane_vmids = [for i in range(local.control_plane_count) : var.starting_vmid + i]
  worker_vmids         = [for i in range(var.worker_count) : var.starting_vmid + local.control_plane_count + i]

  # Derived once here so main.tf's `name` and the auto zone-label logic
  # below can't drift apart from each other.
  control_plane_names = [for i in range(local.control_plane_count) : "${var.cluster_name}-${var.control_plane_role_name}-${format("%02d", i + 1)}"]
  worker_names         = [for i in range(var.worker_count) : "${var.cluster_name}-${var.worker_role_name}-${format("%02d", i + 1)}"]

  # ipv4_addresses is a list-of-lists, one inner list per NIC, index 0 is
  # always the loopback (127.0.0.1). Index 1 is the first real NIC, which is
  # the only NIC this project attaches, so [1][0] is "the" IP of the VM.
  control_plane_ips = [for cp in proxmox_virtual_environment_vm.control_plane : cp.ipv4_addresses[1][0]]
  control_plane_ip  = local.control_plane_ips[0]
  worker_ips        = [for w in proxmox_virtual_environment_vm.worker : w.ipv4_addresses[1][0]]

  use_kube_vip = var.control_plane_vip != null && trimspace(var.control_plane_vip) != ""

  control_plane_endpoint = local.use_kube_vip ? var.control_plane_vip : coalesce(var.control_plane_endpoint_override, local.control_plane_ip)

  worker_join_command_file = "${path.module}/generated/kubeadm-join-worker.sh"

  longhorn_replica_count = coalesce(var.longhorn_replica_count, min(var.worker_count, 3))

  # Persistence only makes sense if Longhorn is actually providing a
  # StorageClass; otherwise fall back cleanly to ephemeral storage rather
  # than leaving PVCs stuck Pending with nothing to satisfy them.
  prometheus_use_persistence = var.install_longhorn

  prometheus_values = templatefile("${path.module}/templates/prometheus-values.yaml.tpl", {
    retention                = var.prometheus_retention
    use_persistence           = local.prometheus_use_persistence
    storage_class              = "longhorn"
    prometheus_storage_size    = var.prometheus_storage_size
    alertmanager_storage_size  = var.alertmanager_storage_size
    grafana_storage_size       = var.grafana_storage_size
    grafana_admin_password     = var.grafana_admin_password
  })

  # Automatic zone label per node, from wherever it's actually placed --
  # accurate now that placement is genuinely per-instance above, unlike a
  # single shared control_plane_node/worker_node value would be.
  auto_zone_labels = var.label_zone_automatically ? merge(
    { for i, n in local.control_plane_names : n => { (var.zone_label_key) = local.control_plane_placement[i] } },
    { for i, n in local.worker_names : n => { (var.zone_label_key) = local.worker_placement[i] } },
  ) : {}

  # Deep-merged per node: the automatic zone label is the base, var.node_labels
  # layers on top and wins on any key it also sets for that node (including
  # zone_label_key itself, if the user wants to override the derived value).
  effective_node_labels = {
    for node_name in distinct(concat(keys(local.auto_zone_labels), keys(var.node_labels))) :
    node_name => merge(
      try(local.auto_zone_labels[node_name], {}),
      try(var.node_labels[node_name], {}),
    )
  }

  # One "wait for it to exist, then label it" pair of kubectl commands per
  # label in effective_node_labels, flattened into a single ordered list.
  node_label_commands = flatten([
    for node_name, labels in local.effective_node_labels : concat(
      ["kubectl wait --for=create node/${node_name} --timeout=120s"],
      [for key, value in labels : "kubectl label node ${node_name} ${key}=${value} --overwrite"]
    )
  ])

  kubeadm_config = templatefile("${path.module}/templates/kubeadm-config.yaml.tpl", {
    cluster_name            = var.cluster_name
    kubeadm_api_version     = var.kubeadm_api_version
    pod_cidr                = var.pod_network_cidr
    service_cidr            = var.kubernetes_service_cidr
    control_plane_endpoint  = local.control_plane_endpoint
    advertise_address       = local.control_plane_ip
  })

  calico_custom_resources = templatefile("${path.module}/templates/calico-custom-resources.yaml.tpl", {
    pod_cidr      = var.pod_network_cidr
    encapsulation = var.calico_encapsulation
  })

  traefik_values = templatefile("${path.module}/templates/traefik-values.yaml.tpl", {
    service_type       = var.traefik_service_type
    enable_ingress      = var.traefik_enable_ingress
    enable_gateway_api  = var.traefik_enable_gateway_api
  })

  metallb_config = templatefile("${path.module}/templates/metallb-config.yaml.tpl", {
    addresses = var.metallb_address_pool
  })

  cloudflare_secret_manifest = templatefile("${path.module}/templates/cloudflare-secret.yaml.tpl", {
    secret_name = var.cloudflare_secret_name
    namespace   = var.cert_manager_namespace
    api_token   = var.cloudflare_api_token
  })

  cluster_issuers_manifest = templatefile("${path.module}/templates/cluster-issuers.yaml.tpl", {
    acme_email  = var.acme_email
    secret_name = var.cloudflare_secret_name
  })
}
