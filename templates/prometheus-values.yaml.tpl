prometheus:
  prometheusSpec:
    retention: ${retention}
%{ if use_persistence ~}
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${storage_class}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${prometheus_storage_size}
%{ endif ~}

alertmanager:
%{ if use_persistence ~}
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${storage_class}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${alertmanager_storage_size}
%{ endif ~}

grafana:
  persistence:
    enabled: ${use_persistence}
%{ if use_persistence ~}
    storageClassName: ${storage_class}
    size: ${grafana_storage_size}
%{ endif ~}
%{ if grafana_admin_password != "" ~}
  adminPassword: ${grafana_admin_password}
%{ endif ~}
