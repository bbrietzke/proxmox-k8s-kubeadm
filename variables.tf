#############################################
# Proxmox connection
#############################################

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token, in the form 'user@realm!tokenid=uuid'"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification when talking to the Proxmox API"
  type        = bool
  default     = false
}

variable "proxmox_ssh_username" {
  description = "Username the Proxmox provider uses over SSH to the node (for disk import/resize operations)"
  type        = string
  default     = "root"
}

variable "proxmox_node" {
  description = "Default Proxmox node name for VMs, used as a fallback when control_plane_node / worker_node are left unset. In a single-node Proxmox setup, this is the only node variable you need."
  type        = string
  default     = null
}

variable "control_plane_node" {
  description = "Default Proxmox node to place control-plane VMs on. Falls back to var.proxmox_node if left unset. Overridden per instance by control_plane_nodes[*].placement_zone. Changing this on an existing cluster migrates the VM in place (see migrate below) rather than destroying and recreating it."
  type        = string
  default     = null
}

variable "worker_node" {
  description = "Default Proxmox node to place worker VMs on. Falls back to var.proxmox_node if left unset. Overridden per instance by worker_nodes[*].placement_zone. Changing this on an existing cluster migrates the VM in place (see migrate below) rather than destroying and recreating it."
  type        = string
  default     = null
}

variable "worker_nodes" {
  description = "Per-worker placement overrides, keyed by instance index as a string (\"0\", \"1\", ... matching count.index). An entry's placement_zone sends that one worker to a specific Proxmox node instead of the var.worker_node default; omit placement_zone (or the whole entry) to just use the default. Example: { 0 = { placement_zone = \"pve02\" }, 1 = {} }. Doesn't need an entry for every worker -- indices with no entry use the default."
  type = map(object({
    placement_zone = optional(string)
  }))
  default = {}
}

variable "control_plane_nodes" {
  description = "Per-control-plane placement overrides, same shape and semantics as worker_nodes, keyed by instance index (\"0\" is always the first control plane, the one kubeadm_init runs against)."
  type = map(object({
    placement_zone = optional(string)
  }))
  default = {}
}

variable "template_node" {
  description = "Proxmox node where template_vm_id actually lives, if different from control_plane_node / worker_node. Required in multi-node setups where the template only exists on one node -- without it, cloning onto a different target node will fail. Leave null if the template lives on the same node as each VM's target (single-node setups)."
  type        = string
  default     = null
}

variable "vm_migrate_timeout" {
  description = "Timeout in seconds for a Proxmox VM migration triggered by changing control_plane_node / worker_node"
  type        = number
  default     = 1800
}

variable "node_labels" {
  description = "Extra labels to apply to Kubernetes nodes once they've joined, keyed by node name (this project's node names equal the VM name -- see control_plane_role_name/worker_role_name -- since cloud-init sets the guest hostname from the VM name, and kubelet registers under that hostname). Example: { \"homelab-worker-01\" = { disktype = \"ssd\" } }. Applied via 'kubectl label node ... --overwrite', so this works for any label including reserved kubernetes.io/ ones -- not just custom ones a kubelet could self-apply at join time. Merged with (and taking precedence over) the automatic zone label from label_zone_automatically, if that's also on."
  type        = map(map(string))
  default     = {}
}

variable "label_zone_automatically" {
  description = "When true, automatically labels every node with the Proxmox node it's actually placed on (from control_plane_node/worker_node or their per-instance overrides in control_plane_nodes/worker_nodes), under the key zone_label_key. Set false to only apply whatever's explicitly listed in node_labels."
  type        = bool
  default     = true
}

variable "zone_label_key" {
  description = "Label key used for the automatic placement-zone label when label_zone_automatically = true. Defaults to the well-known topology.kubernetes.io/zone label -- the documented Kubernetes convention for a node's failure/topology zone -- so anything that already understands it (topology-aware scheduling, pod topology spread constraints, storage provisioners) picks it up without extra config."
  type        = string
  default     = "topology.kubernetes.io/zone"
}

variable "datastore_id" {
  description = "Proxmox storage/datastore ID used for VM disks"
  type        = string
  default     = "local-lvm"
}

#############################################
# Template / cloning
#############################################

variable "template_vm_id" {
  description = "VM ID of the existing Kubernetes template to clone for both control plane and worker nodes"
  type        = number
  default     = 999999994
}

variable "starting_vmid" {
  description = "VMID assigned to the first cloned VM. Control-plane nodes are assigned this ID and the ones immediately after it; worker nodes then continue upward from wherever the control-plane range ends."
  type        = number
  default     = 9000
}

variable "network_bridge" {
  description = "Proxmox network bridge to attach VM NICs to"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "Optional VLAN tag for the VM NIC. Leave null for no tagging"
  type        = number
  default     = null
}

#############################################
# Control plane nodes
#############################################

variable "control_plane_ha" {
  description = "If true, create and join three control-plane nodes (HA). If false, create a single control-plane node."
  type        = bool
  default     = false
}

variable "control_plane_endpoint_override" {
  description = "Optional stable endpoint (VIP, load balancer DNS name, or IP) used as kubeadm's controlPlaneEndpoint. Ignored if control_plane_vip is set. If both are left null, the first control-plane node's own IP is used -- fine for control_plane_ha = false, but a single point of failure for real HA."
  type        = string
  default     = null
}

variable "control_plane_vip" {
  description = "Floating VIP for the control plane, managed by kube-vip (ARP mode, running as a static pod on every control-plane node). When set, this becomes kubeadm's controlPlaneEndpoint and control_plane_endpoint_override is ignored. Leave null to skip kube-vip entirely."
  type        = string
  default     = null
}

variable "kube_vip_interface" {
  description = "Network interface kube-vip uses for ARP on each control-plane node. Must match the template's NIC name (e.g. eth0, ens18) -- check the template if unsure. Only used when control_plane_vip is set."
  type        = string
  default     = "eth0"
}

variable "kube_vip_version" {
  description = "kube-vip image tag used to generate the static pod manifest. Only used when control_plane_vip is set."
  type        = string
  default     = "v0.8.0"
}

variable "control_plane_role_name" {
  description = "Role label used in control-plane VM names: <cluster_name>-<this>-<NN>, e.g. homelab-controlplane-01"
  type        = string
  default     = "controlplane"
}

variable "control_plane_cores" {
  type    = number
  default = 4
}

variable "control_plane_memory" {
  description = "Memory in MB"
  type        = number
  default     = 8192
}

variable "control_plane_boot_disk_size" {
  description = "Size in GB of the cloned boot disk for control plane nodes"
  type        = number
  default     = 64
}

#############################################
# Worker nodes
#############################################

variable "worker_count" {
  description = "Number of worker nodes to create"
  type        = number
  default     = 3
}

variable "worker_role_name" {
  description = "Role label used in worker VM names: <cluster_name>-<this>-<NN>, e.g. homelab-worker-01"
  type        = string
  default     = "worker"
}

variable "worker_cores" {
  type    = number
  default = 4
}

variable "worker_memory" {
  description = "Memory in MB"
  type        = number
  default     = 8192
}

variable "worker_boot_disk_size" {
  description = "Size in GB of the cloned boot disk for worker nodes"
  type        = number
  default     = 64
}

variable "worker_data_disk_size" {
  description = "Size in GB of the second (data) disk attached to each worker node"
  type        = number
  default     = 256
}

variable "prepare_worker_data_disk" {
  description = "Whether to format and mount the worker data disk (scsi1) automatically. Set false to leave the raw disk alone and handle it yourself."
  type        = bool
  default     = true
}

variable "worker_data_disk_device" {
  description = "In-guest block device path for the worker data disk. A Proxmox scsi1 disk normally shows up in the guest as /dev/sdb with the standard virtio-scsi controller -- verify against your template if it uses something else (e.g. /dev/vdb for a virtio-blk controller)."
  type        = string
  default     = "/dev/sdb"
}

variable "worker_data_disk_filesystem" {
  description = "Filesystem used to format the worker data disk. ext4 needs nothing extra on virtually any base image; xfs needs xfsprogs present on the template."
  type        = string
  default     = "ext4"
}

variable "worker_data_disk_mount_point" {
  description = "Where the worker data disk is mounted. Defaults to Longhorn's own default data path (/var/lib/longhorn), so Longhorn can use it directly with no extra configuration once you install it."
  type        = string
  default     = "/var/lib/longhorn"
}

#############################################
# Longhorn, applied after Calico is up
#############################################

variable "install_longhorn" {
  description = "Whether to install Longhorn (distributed block storage), via its Helm chart, once the cluster is up. Only runs against workers -- control planes carry kubeadm's default NoSchedule taint, so Longhorn's DaemonSet won't land there anyway, which matches reality since only workers have the dedicated data disk."
  type        = bool
  default     = true
}

variable "longhorn_version" {
  description = "Longhorn Helm chart version (matches the app version 1:1) to install"
  type        = string
  default     = "1.11.2"
}

variable "longhorn_namespace" {
  description = "Namespace Longhorn is installed into"
  type        = string
  default     = "longhorn-system"
}

variable "longhorn_replica_count" {
  description = "Number of replicas per volume (defaultSettings.defaultReplicaCount and persistence.defaultClassReplicaCount). Leave null to auto-derive min(worker_count, 3) -- Longhorn's own upstream default is 3, but that only makes sense with at least 3 workers to spread replicas across; fewer workers than replicas just means replicas piling up wherever they fit, which defeats the point."
  type        = number
  default     = null
}

variable "longhorn_extra_values" {
  description = "Raw extra Helm values YAML for the Longhorn chart, passed as a -f file (in addition to the replica-count --set flags this project always sets). See https://github.com/longhorn/charts and https://longhorn.io/docs/latest/references/settings/ for the full values/settings reference. Leave empty for none."
  type        = string
  default     = ""
}

#############################################
# kube-prometheus-stack (Prometheus, Alertmanager, Grafana), after Calico
#############################################

variable "install_prometheus" {
  description = "Whether to install the kube-prometheus-stack Helm chart (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) once the cluster is up."
  type        = bool
  default     = true
}

variable "prometheus_chart_version" {
  description = "kube-prometheus-stack Helm chart version to install"
  type        = string
  default     = "87.19.2"
}

variable "prometheus_namespace" {
  description = "Namespace kube-prometheus-stack is installed into"
  type        = string
  default     = "monitoring"
}

variable "prometheus_retention" {
  description = "How long Prometheus retains metrics before expiring them"
  type        = string
  default     = "15d"
}

variable "prometheus_storage_size" {
  description = "Size of Prometheus's persistent volume. Only used when install_longhorn = true -- otherwise Prometheus falls back to ephemeral storage rather than a PVC with no StorageClass to satisfy it."
  type        = string
  default     = "50Gi"
}

variable "alertmanager_storage_size" {
  description = "Size of Alertmanager's persistent volume. Only used when install_longhorn = true, same reasoning as prometheus_storage_size."
  type        = string
  default     = "5Gi"
}

variable "grafana_storage_size" {
  description = "Size of Grafana's persistent volume. Only used when install_longhorn = true, same reasoning as prometheus_storage_size."
  type        = string
  default     = "5Gi"
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Leave empty (the default) to let the chart auto-generate one instead -- retrievable with: kubectl -n <prometheus_namespace> get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
  type        = string
  sensitive   = true
  default     = ""
}

variable "prometheus_extra_values" {
  description = "Raw extra Helm values YAML for the kube-prometheus-stack chart, passed as a -f file after the one this project generates (so it can override anything). See https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack for the full values reference. Leave empty for none."
  type        = string
  default     = ""
}

#############################################
# prometheus-adapter (metrics.k8s.io, replaces metrics-server)
#############################################

variable "install_prometheus_adapter" {
  description = "Whether to install prometheus-adapter, which implements the metrics.k8s.io resource-metrics API (what kubectl top and the Horizontal Pod Autoscaler use) backed by Prometheus queries instead of a separate metrics-server. Requires install_prometheus = true."
  type        = bool
  default     = true

  validation {
    condition     = !var.install_prometheus_adapter || var.install_prometheus
    error_message = "install_prometheus_adapter requires install_prometheus = true -- it queries the Prometheus this project installs, not a standalone one."
  }
}

variable "prometheus_adapter_chart_version" {
  description = "prometheus-adapter Helm chart version to install"
  type        = string
  default     = "4.9.0"
}

variable "prometheus_adapter_extra_values" {
  description = "Raw extra Helm values YAML for the prometheus-adapter chart, passed as a -f file (in addition to the prometheus.url/prometheus.port --set flags this project always sets). Use this to tune rules.resource, rules.custom, metricsRelistInterval, etc. See https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-adapter for the full values reference. Leave empty for none -- the chart's own rules.default = true is enough for kubectl top / basic CPU+memory HPA out of the box."
  type        = string
  default     = ""
}

#############################################
# Cloud-init
#############################################

variable "ci_username" {
  description = "Username to create on every VM via cloud-init"
  type        = string
}

variable "ci_password" {
  description = "Password for the cloud-init user"
  type        = string
  sensitive   = true
}

variable "ssh_public_keys" {
  description = "List of SSH public keys to authorize for the cloud-init user"
  type        = list(string)
}

variable "ssh_private_key_path" {
  description = "Path (on the machine running Terraform) to the private key matching one of ssh_public_keys. Used by Terraform to SSH into nodes for kubeadm provisioning"
  type        = string
}

#############################################
# Kubernetes / kubeadm
#############################################

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to 'kubeadm init'. No CNI is installed by this project, but kubeadm still needs this recorded in the cluster config for whichever CNI you install afterwards"
  type        = string
  default     = "10.244.0.0/16"
}

variable "kubernetes_service_cidr" {
  description = "Service network CIDR passed to 'kubeadm init'"
  type        = string
  default     = "10.96.0.0/12"
}

variable "cluster_name" {
  description = "Cluster name written into the generated kubeadm ClusterConfiguration (templates/kubeadm-config.yaml.tpl)"
  type        = string
  default     = "kubernetes"
}

variable "kubeadm_api_version" {
  description = "kubeadm.k8s.io config API version used in templates/kubeadm-config.yaml.tpl (e.g. v1beta3, v1beta4). Must match what the kubeadm binary on your template actually supports -- if 'kubeadm init' complains about an old/unsupported API spec, SSH into the node, run 'kubeadm config migrate --old-config <(cat generated file) --new-config -' (or just check 'kubeadm version') to find the right value, and set it here."
  type        = string
  default     = "v1beta4"
}

#############################################
# CNI (Calico), applied after the cluster is up
#############################################

variable "install_calico" {
  description = "Whether to install Calico as the cluster's CNI automatically once the control plane and all nodes have joined. Set false to leave the cluster with no CNI (matching this project's original no-CNI default) and install something else yourself."
  type        = bool
  default     = true
}

variable "calico_version" {
  description = "Calico release tag used to fetch the CRD bundle and Tigera operator manifests (https://raw.githubusercontent.com/projectcalico/calico/<version>/manifests/{v1_crd_projectcalico_org.yaml,tigera-operator.yaml})"
  type        = string
  default     = "v3.32.2"
}

variable "calico_encapsulation" {
  description = "Encapsulation mode for Calico's default IP pool (VXLAN, IPIP, VXLANCrossSubnet, IPIPCrossSubnet, or None if your fabric already routes pod CIDRs)"
  type        = string
  default     = "VXLAN"
}

#############################################
# Ingress (Traefik), applied after Calico is up
#############################################

variable "install_traefik" {
  description = "Whether to install Traefik as an ingress controller, via its Helm chart, once the cluster is up."
  type        = bool
  default     = true
}

variable "helm_version" {
  description = "Helm CLI release tag installed on the control-plane node (via get-helm-3) if helm isn't already on PATH"
  type        = string
  default     = "v3.21.3"
}

variable "traefik_chart_version" {
  description = "traefik/traefik Helm chart version (not the Traefik Proxy app version) to install"
  type        = string
  default     = "41.5.0"
}

variable "traefik_namespace" {
  description = "Namespace Traefik is installed into"
  type        = string
  default     = "traefik"
}

variable "traefik_service_type" {
  description = "Kubernetes Service type for Traefik (ClusterIP, NodePort, or LoadBalancer). Defaults to LoadBalancer since this project now installs MetalLB as a LoadBalancer provisioner (install_metallb). If you set install_metallb = false and leave this at LoadBalancer, the Service will sit in <pending> forever -- set it to NodePort or ClusterIP instead in that case."
  type        = string
  default     = "LoadBalancer"
}

variable "traefik_enable_gateway_api" {
  description = "Enable Traefik's Kubernetes Gateway API provider (providers.kubernetesGateway.enabled). When true, this project also installs the upstream Gateway API CRDs (gateway_api_version) first, since the Traefik chart no longer bundles them."
  type        = bool
  default     = true
}

variable "gateway_api_version" {
  description = "Gateway API CRD release tag installed when traefik_enable_gateway_api = true (https://github.com/kubernetes-sigs/gateway-api/releases/download/<version>/standard-install.yaml)"
  type        = string
  default     = "v1.6.1"
}

variable "traefik_enable_ingress" {
  description = "Enable Traefik's classic Kubernetes Ingress provider (providers.kubernetesIngress.enabled)"
  type        = bool
  default     = false
}

variable "traefik_extra_values" {
  description = "Raw extra Helm values YAML for the Traefik chart, passed as a second -f file after the one this project generates (so it can override anything). Use this for anything not covered by the named variables above -- e.g. gateway.listeners, ports, additionalArguments, ingressRoute.dashboard, resources, etc. See https://github.com/traefik/traefik-helm-chart for the full values reference. Leave empty for none."
  type        = string
  default     = ""
}

#############################################
# cert-manager, applied after Calico is up
#############################################

variable "install_cert_manager" {
  description = "Whether to install cert-manager, via its Helm chart, once the cluster is up. Note: this installs the controller/webhook/cainjector and CRDs only -- it does not create any Issuer or ClusterIssuer, since which one makes sense (Let's Encrypt HTTP-01, Let's Encrypt DNS-01 with a specific provider, or a self-signed/internal CA) depends on your domain and DNS setup."
  type        = bool
  default     = true
}

variable "cert_manager_version" {
  description = "cert-manager release tag (Helm chart version and app version match 1:1 for this chart) to install"
  type        = string
  default     = "v1.21.0"
}

variable "cert_manager_namespace" {
  description = "Namespace cert-manager is installed into"
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_extra_values" {
  description = "Raw extra Helm values YAML for the cert-manager chart, passed as a -f file (in addition to --set crds.enabled=true, which this project always sets). See https://cert-manager.io/docs/installation/helm/#configuration for the full values reference. Leave empty for none."
  type        = string
  default     = ""
}

#############################################
# Let's Encrypt ClusterIssuers via Cloudflare DNS-01
#############################################

variable "install_letsencrypt_cloudflare_issuers" {
  description = "Whether to create letsencrypt-staging and letsencrypt-production ClusterIssuers, both using cert-manager's Cloudflare DNS-01 solver, once cert-manager is up."
  type        = bool
  default     = true
}

variable "acme_email" {
  description = "Contact email used for both Let's Encrypt ACME account registrations (staging and production). Required when install_letsencrypt_cloudflare_issuers = true."
  type        = string
  default     = ""

  validation {
    condition     = !var.install_letsencrypt_cloudflare_issuers || length(var.acme_email) > 0
    error_message = "acme_email must be set when install_letsencrypt_cloudflare_issuers = true."
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (scoped -- Zone:DNS:Edit on the relevant zone(s) -- not the legacy Global API Key) used by both ClusterIssuers' DNS-01 solver. Required when install_letsencrypt_cloudflare_issuers = true. Stored in a Kubernetes Secret in cert_manager_namespace and, like this project's other secrets (ci_password, the Proxmox API token), also ends up in Terraform state -- use a remote backend with encryption/access control for anything beyond a lab."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = !var.install_letsencrypt_cloudflare_issuers || length(var.cloudflare_api_token) > 0
    error_message = "cloudflare_api_token must be set when install_letsencrypt_cloudflare_issuers = true."
  }
}

variable "cloudflare_secret_name" {
  description = "Name of the Kubernetes Secret (created in cert_manager_namespace) that stores the Cloudflare API token"
  type        = string
  default     = "cloudflare-api-token-secret"
}

#############################################
# MetalLB (LoadBalancer provisioner), applied after Calico is up
#############################################

variable "install_metallb" {
  description = "Whether to install MetalLB (Layer2/ARP mode) once the cluster is up, so Services of type LoadBalancer actually get an external IP."
  type        = bool
  default     = true
}

variable "metallb_version" {
  description = "MetalLB release tag used to fetch its install manifest (https://raw.githubusercontent.com/metallb/metallb/<version>/config/manifests/metallb-native.yaml)"
  type        = string
  default     = "v0.15.3"
}

variable "metallb_address_pool" {
  description = "IP ranges or CIDRs MetalLB hands out as LoadBalancer external IPs, e.g. [\"192.168.3.200-192.168.3.220\"]. Must be free addresses on the same L2 segment as your nodes (ARP mode doesn't route across subnets) and not overlap DHCP, the kube-vip control-plane VIP, or anything else already in use. No default -- this is specific to your network, so it must be set explicitly when install_metallb = true."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.install_metallb || length(var.metallb_address_pool) > 0
    error_message = "metallb_address_pool must be set (at least one range/CIDR) when install_metallb = true."
  }
}
