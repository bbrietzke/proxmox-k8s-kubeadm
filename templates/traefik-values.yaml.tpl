service:
  type: ${service_type}

providers:
  kubernetesIngress:
    enabled: ${enable_ingress}
  kubernetesGateway:
    enabled: ${enable_gateway_api}
