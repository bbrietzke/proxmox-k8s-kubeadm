apiVersion: kubeadm.k8s.io/${kubeadm_api_version}
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${advertise_address}
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/${kubeadm_api_version}
kind: ClusterConfiguration
clusterName: ${cluster_name}
controlPlaneEndpoint: "${control_plane_endpoint}:6443"
networking:
  podSubnet: ${pod_cidr}
  serviceSubnet: ${service_cidr}
