# Proxmox kubeadm cluster (Terraform)

Clones VM template `999999994` to create one control plane node and N worker
nodes on Proxmox, provisions each with cloud-init (username/password/SSH
keys), bootstraps the cluster with `kubeadm init`, and auto-joins the workers
using `kubeadm token create --print-join-command`. Once every node has
joined, it installs Calico as the CNI, MetalLB as a LoadBalancer
provisioner, Traefik as the ingress controller, cert-manager with
Let's Encrypt staging/production ClusterIssuers via Cloudflare DNS-01,
Longhorn (distributed block storage, using each worker's formatted data
disk), kube-prometheus-stack (Prometheus, Alertmanager, Grafana), and
prometheus-adapter (serving `metrics.k8s.io` from Prometheus in place of a
standalone metrics-server) (each toggleable via `install_calico` /
`install_metallb` / `install_traefik` / `install_cert_manager` /
`install_letsencrypt_cloudflare_issuers` / `install_longhorn` /
`install_prometheus` / `install_prometheus_adapter`).

## Assumptions about the template (VM 999999994)

This project clones the template but does not install software on it, so the
template itself must already have:

- `containerd` (or another CRI) installed and enabled
- `kubeadm`, `kubelet`, `kubectl` installed and held at a matching version
- `qemu-guest-agent` installed and enabled (needed so Terraform can read the
  VM's IP address after boot — the `agent { enabled = true }` block in
  `main.tf` depends on this)
- Cloud-init drive support (the template was created with a Cloud-Init drive
  attached in Proxmox)
- The kernel modules / sysctls kubeadm expects at boot (`overlay`, `br_netfilter`,
  `net.bridge.bridge-nf-call-iptables=1`, swap disabled, etc.)

## Layout

| File | Purpose |
|---|---|
| `providers.tf` | Proxmox, local, and null provider configuration |
| `variables.tf` | All inputs (connection info, sizing, cloud-init, kubeadm) |
| `main.tf` | Control plane + worker VM resources, cloned from the template |
| `kubeadm.tf` | `kubeadm init`, join-command retrieval, and worker join automation |
| `calico.tf` | Installs Calico (CNI) via the Tigera operator once the cluster is up |
| `metallb.tf` | Installs MetalLB (LoadBalancer provisioner, Layer2/ARP mode) |
| `traefik.tf` | Installs Traefik (ingress controller) via Helm |
| `cert-manager.tf` | Installs cert-manager (controller/webhook/CRDs only, no issuer) via Helm |
| `letsencrypt-cloudflare.tf` | Creates letsencrypt-staging/-production ClusterIssuers using Cloudflare DNS-01 |
| `node-labels.tf` | Applies extra labels (e.g. a zone) to nodes once they've joined |
| `worker-data-disk.tf` | Formats and mounts each worker's data disk (for Longhorn or similar) |
| `longhorn.tf` | Installs prereqs (open-iscsi/nfs-common) and Longhorn itself via Helm |
| `prometheus.tf` | Installs kube-prometheus-stack (Prometheus, Alertmanager, Grafana) via Helm |
| `prometheus-adapter.tf` | Installs prometheus-adapter, serving metrics.k8s.io from Prometheus (replaces metrics-server) |
| `locals.tf` | VMID sequencing, node IPs, control-plane endpoint, rendered kubeadm config |
| `templates/kubeadm-config.yaml.tpl` | Parameterized kubeadm `InitConfiguration`/`ClusterConfiguration` (cluster name, pod CIDR, service CIDR, control-plane endpoint) |
| `outputs.tf` | Node IPs, VMIDs, join commands, kubeconfig path |
| `terraform.tfvars.example` | Copy to `terraform.tfvars` and fill in |
| `Makefile` | `make apply`/`plan`/`destroy`, defaulting to sequential (`-parallelism=1`) VM creation |

## Worker disks

Each worker gets two disks, both driven off the same clone:

- `scsi0` — boot disk (resized from the clone), sized by `worker_boot_disk_size`
- `scsi1` — a second, independent data disk sized by `worker_data_disk_size`
  (defaults to **256** GB)

`worker-data-disk.tf` formats and mounts the data disk automatically —
see the next section. Set `prepare_worker_data_disk = false` if you'd
rather partition/format/mount it yourself (from cloud-init on the
template, by hand, or with another tool).

## Worker data disk (for Longhorn)

Once each worker VM exists, `worker-data-disk.tf` SSHes in and:

1. Checks `blkid` on `worker_data_disk_device` (default `/dev/sdb`, which
   is where a Proxmox `scsi1` disk normally shows up in the guest with the
   standard virtio-scsi controller) — **only formats it if it has no
   existing filesystem**. This is the important safety property: re-apply
   this against a worker that's already running Longhorn with real data on
   that disk, and it does nothing rather than wiping it.
2. Formats it (`worker_data_disk_filesystem`, default `ext4` — needs
   nothing extra on virtually any base image; `xfs` needs `xfsprogs`
   present on the template).
3. Adds an `/etc/fstab` entry by UUID (not by device path, since device
   naming isn't guaranteed stable across reboots if disks are ever added
   or reordered) and mounts it at `worker_data_disk_mount_point` — which
   defaults to `/var/lib/longhorn`, Longhorn's own default data path, so
   once you install Longhorn it picks up this disk with zero extra
   configuration.
4. Verifies the mount actually happened (`mountpoint -q`) rather than
   silently leaving whatever's writing there to fall through to the root
   filesystem instead.

Set `prepare_worker_data_disk = false` to skip all of this and leave the
raw, unformatted disk alone. This project doesn't install Longhorn itself
— only prepares the disk it would use — so this is useful independent of
whether or when you actually install it.

## Placing nodes on specific Proxmox servers, and migrating between them

`control_plane_node` and `worker_node` independently pick the *default*
Proxmox node each role's VMs live on, falling back to `proxmox_node` if
left unset (so a single-node setup only needs `proxmox_node`).

**Per-instance overrides**: `worker_nodes`/`control_plane_nodes` are maps
keyed by instance index (`"0"`, `"1"`, ... — `"0"` is always the first
control plane, the one `kubeadm_init` runs against) that send individual
VMs to a specific node instead of the shared default:

```hcl
worker_nodes = {
  0 = { placement_zone = "pve02" }
  1 = {}
  2 = {}
}
```

An entry with no `placement_zone`, or no entry at all for that index, just
uses `worker_node`. You don't need to cover every index — this is a sparse
overlay, not a full replacement list. This is genuinely spreading VMs
across your Proxmox cluster rather than clustering them all on one node,
which is the actual point of having multiple Proxmox servers behind a
Kubernetes cluster: a single Proxmox node failing shouldn't be able to take
out every control plane or every worker at once.

This mechanism is deliberately a lookup layered on top of `count`, not a
switch to `for_each` — so adding, removing, or changing an override never
changes a VM resource's address in state. Only that one instance's
`node_name` shows a diff.

Both VM resources set `migrate = true`. In the `bpg/proxmox` provider, this
means changing `node_name` (whether via `control_plane_node`/`worker_node`
or a per-instance override above, then re-applying) makes Terraform call
Proxmox's actual **migrate** API to move the existing VM to its new node,
rather than destroying and recreating it. So to move your workers to
`pve01` and control planes to `pve02` across the board:

```hcl
control_plane_node = "pve02"
worker_node         = "pve01"
```

then `terraform apply` — plan will show an in-place update (`~`), not a
replacement (`-/+`), for each VM's `node_name`.

A few things that affect whether this goes smoothly:

- **Shared storage makes this trivial** (Ceph, NFS, etc. available to both
  nodes) — Proxmox can live-migrate without copying disks. A Ceph pool as
  `datastore_id` (as in `terraform.tfvars.example`) is exactly this case:
  the disk never moves, only VM state does, so migration is fast with no
  real downtime.
- **Local-only storage** (e.g. `local-lvm` on each node separately) still
  works, but Proxmox has to copy the disk data between nodes as part of the
  migration, which takes longer and may require the VM to be shut down for
  an offline migration rather than staying up for a live one, depending on
  your Proxmox version and storage config.
- **The target node needs a datastore with the same name** as
  `datastore_id` (default `local-lvm`) — if `pve01` and `pve02` name their
  local storage differently, the migration will fail; rename to match or
  use shared storage.
- `vm_migrate_timeout` (default 1800s) caps how long Terraform waits for
  the migration to finish — raise it for large local-storage disk copies.

**`template_node`**: your template (`999999994`) only exists on one
physical node. If `control_plane_node`/`worker_node` point at a *different*
node than that, the clone step itself needs to know where to find the
template — set `template_node` to wherever it actually lives. The provider
then clones to the template's own node first and migrates the clone to the
target node afterward (a Proxmox API limitation, not something this
project works around). Leave `template_node` unset only if the template
already exists on the same node you're deploying to.

## VM names

Every VM is named `<cluster_name>-<role>-<NN>`, e.g. with
`cluster_name = "homelab"` and defaults: `homelab-controlplane-01`,
`homelab-controlplane-02`, `homelab-worker-01`, `homelab-worker-02`, ...
The role segment (`controlplane` / `worker` by default) comes from
`control_plane_role_name` / `worker_role_name` if you want to change it, and
the number is always zero-padded to two digits.

## VMIDs

`starting_vmid` (default `9000`) is the VMID of the first cloned VM.
Control-plane nodes claim the range starting there; workers continue
upward from wherever the control-plane range ends:

- `control_plane_ha = false` (1 CP): control plane = `9000`, workers = `9001, 9002, 9003, ...`
- `control_plane_ha = true` (3 CPs): control planes = `9000, 9001, 9002`, workers = `9003, 9004, 9005, ...`

## Control plane HA

`control_plane_ha` (bool) is the single switch:

- `false` (default) → one control-plane node
- `true` → three control-plane nodes, all joined into the cluster

How the join works: `kubeadm init --config=... --upload-certs` runs on the
first control-plane node, which produces the worker join command, pulled
back locally as `generated/kubeadm-join-worker.sh`. When
`control_plane_ha = true`, each of the other two control-plane nodes gets
its own **freshly regenerated** join command + certificate-key
immediately before it joins (`generated/kubeadm-join-control-plane-fresh-<N>.sh`)
rather than reusing one generated once, early, during `kubeadm_init` —
kubeadm's uploaded certs have a hard 2-hour TTL, and with sequential VM
creation and a control-planes-before-workers build order, a slower apply
can easily take long enough for a value generated that early to expire
before a later control plane actually gets around to joining. Regenerating
right before each join, instead of reusing a cached value, avoids that
regardless of how long the rest of the apply takes.

**This does not stand up a load balancer or VIP for you.** kubeadm needs a
stable `controlPlaneEndpoint` to let additional control planes join and for
clients to fail over between API servers. By default this project points
`controlPlaneEndpoint` at the first control-plane node's own IP, which lets
`kubeadm init --upload-certs` and the HA join succeed, but it is **not**
true HA — if that first node goes down, the endpoint goes down with it. Set
`control_plane_endpoint_override` to a real VIP/load balancer address, or
set `control_plane_vip` to have this project run kube-vip for you (see
below), for genuine HA. Rebuild the cluster after changing either
(kubeadm bakes `controlPlaneEndpoint` into the cluster at init time).

## Floating VIP with kube-vip

Set `control_plane_vip` to an IP address and this project deploys
[kube-vip](https://kube-vip.io/) as a static pod on every control-plane
node (ARP mode, leader election) and uses that VIP as kubeadm's
`controlPlaneEndpoint` — this supersedes `control_plane_endpoint_override`
if both are set. This works with `control_plane_ha = false` too (a VIP over
a single node), which is handy if you plan to grow to HA later without
re-pointing anything at a new endpoint.

How it's wired up:

- Before `kubeadm init` runs on the first control-plane node, and before
  each additional control-plane node runs its `kubeadm join
  --control-plane`, Terraform SSHes in and generates
  `/etc/kubernetes/manifests/kube-vip.yaml` using the official
  `kube-vip manifest pod` generator, pulled and run once via `ctr`
  (containerd's CLI, expected to already be present on the template):
  ```
  ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:<version> vip \
    /kube-vip manifest pod --interface <iface> --address <vip> \
    --controlplane --arp --leaderElection | tee /etc/kubernetes/manifests/kube-vip.yaml
  ```
- kubelet picks up that static pod manifest on its own (no restart needed),
  so kube-vip is running and ARPing the VIP to the leader before/while
  `kubeadm init` brings up the API server on that node.
- `kubeadm-config.yaml`'s `controlPlaneEndpoint` is set to the VIP, so certs
  and the cluster's recorded endpoint are correct from the start.

Variables involved:

- `control_plane_vip` — the floating IP (e.g. `192.168.1.50`). Must be free
  on your network and in the same subnet/broadcast domain as the
  control-plane nodes (ARP mode doesn't route across subnets).
- `kube_vip_interface` — NIC name on the template (`eth0`, `ens18`, etc.) —
  get this wrong and ARP announcements won't go out the right interface.
- `kube_vip_version` — kube-vip image tag (default `v0.8.0`).

Prerequisites this doesn't set up for you:

- The control-plane nodes need outbound internet access to pull
  `ghcr.io/kube-vip/kube-vip` (or point them at a local registry mirror).
- `ctr` must be on the template's PATH (it ships with containerd).
- The VIP itself must not be assigned to any other host/DHCP reservation.

## Calico (CNI)

`calico.tf` installs Calico automatically after the control plane, any
additional HA control planes, and all workers have joined — using the
[Tigera operator](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart)
install method, which is the current recommended way to install Calico:

1. Fetches and server-side applies the Calico CRD bundle
   (`v1_crd_projectcalico_org.yaml`) for the pinned `calico_version` — the
   CRDs (`Installation`, `APIServer`, etc.) live in this separate file, not
   in `tigera-operator.yaml` itself, so it has to go first or the next step
   fails with "no matches for kind Installation, ensure CRDs are installed
   first". `--server-side --force-conflicts` avoids `kubectl apply`'s
   client-side annotation size limit, which this bundle is large enough to
   hit.
2. Applies `tigera-operator.yaml` for the same version and waits for the
   operator deployment to become available.
3. Applies a rendered `templates/calico-custom-resources.yaml.tpl` — an
   `Installation` custom resource whose `ipPools[0].cidr` is set to
   `var.pod_network_cidr`, the same variable used in
   `templates/kubeadm-config.yaml.tpl`. Both are rendered from one value, so
   Calico's pool and kubeadm's pod subnet can't drift apart.
4. Waits for `tigerastatus/calico` to first exist (`--for=create`, since
   `kubectl wait` errors immediately on a not-yet-created object rather than
   polling for it) and then to report `condition=Available` — the
   operator's own readiness signal, rather than guessing from pod counts.

Set `install_calico = false` to skip this and leave the cluster with no CNI
(this project's original behavior), if you'd rather install something else
or drive Calico's config by hand.

Two more knobs:

- `calico_version` — the Calico release tag (default `v3.32.2`), used to
  fetch both `v1_crd_projectcalico_org.yaml` and `tigera-operator.yaml`
  from `https://raw.githubusercontent.com/projectcalico/calico/<version>/manifests/`.
  The control-plane node needs outbound internet access for this (same
  requirement as kube-vip pulling from `ghcr.io`).
- `calico_encapsulation` — `VXLAN` by default (works without touching NIC
  offload settings on most virtualized networks). Set to `None` only if
  your underlying network fabric already routes the pod CIDR without
  overlay — not the case for a typical flat Proxmox bridge network.

## MetalLB (LoadBalancer provisioner)

`metallb.tf` installs [MetalLB](https://metallb.io/) in Layer2/ARP mode
after Calico is up, so `Service` objects of type `LoadBalancer` actually
get a real external IP instead of sitting in `<pending>` forever:

1. Fetches and applies `metallb-native.yaml` for the pinned
   `metallb_version`, and waits for the controller deployment to become
   available.
2. Applies a rendered `templates/metallb-config.yaml.tpl` — an
   `IPAddressPool` covering `metallb_address_pool` plus an
   `L2Advertisement` for it. MetalLB's validating webhook can take a few
   seconds to come up after the controller reports `Available`, so this
   apply retries (up to 12 times, 5s apart) rather than racing it, and
   still fails the resource for real if every retry is exhausted.

**`metallb_address_pool` has no default and must be set** when
`install_metallb = true` (Terraform will refuse to apply otherwise) —
this is specific to your network, not something safe to guess. Pick a
range of free addresses on the same L2 segment as your nodes (Layer2 mode
works by ARP, so it doesn't route across subnets or VLANs) that don't
overlap DHCP, the `control_plane_vip` (kube-vip), or anything else already
handed out, e.g. `["192.168.3.200-192.168.3.220"]`. CIDR notation
(`"192.168.3.192/28"`) also works.

Set `install_metallb = false` to skip this — e.g. if you'd rather run BGP
mode by hand, or already have a different LoadBalancer provisioner.

## Traefik (ingress)

`traefik.tf` installs [Traefik](https://traefik.io/) as an ingress
controller after Calico and MetalLB are up, via its official Helm chart
(the recommended install method):

1. Installs Helm on the control-plane node if it isn't already there
   (`get-helm-3`, pinned to `helm_version`) — the template doesn't ship it.
2. `helm repo add traefik https://traefik.github.io/charts` and
   `helm repo update`.
3. `helm upgrade --install traefik traefik/traefik --version
   traefik_chart_version --namespace traefik_namespace --create-namespace
   -f traefik-values.yaml`, where the values file is rendered from
   `templates/traefik-values.yaml.tpl` (currently just sets
   `service.type`).
4. `kubectl rollout status deployment/traefik` to confirm it actually came
   up, not just that Helm returned.

Set `install_traefik = false` to skip this entirely.

**On `traefik_service_type` (default `LoadBalancer`)**: now that MetalLB
provides a real LoadBalancer provisioner, Traefik's Service defaults to
`LoadBalancer` and picks up an IP from `metallb_address_pool` — check
`kubectl get svc -n traefik` for which one it landed on. If you set
`install_metallb = false`, change this to `NodePort` (or `ClusterIP`)
too, or the Service will sit in `<pending>` with no provisioner to satisfy
it.

This install intentionally stays minimal — no TLS/ACME, no forced
HTTP→HTTPS redirect, no exposed dashboard — since none of that was asked
for and each adds real decisions (a domain, a cert resolver, whether the
dashboard should be public).

**Setting Helm values**: three ways in, in the order they're actually
applied (later overrides earlier):

1. **Named variables** for the two things this project treats as
   first-class: `traefik_enable_gateway_api` (default `true`) and
   `traefik_enable_ingress` (default `false`) — i.e. Gateway API on,
   classic Ingress off, by default. These render into
   `templates/traefik-values.yaml.tpl` as
   `providers.kubernetesGateway.enabled` /
   `providers.kubernetesIngress.enabled`. When Gateway API is on, this
   project also installs the upstream Gateway API CRDs first (pinned by
   `gateway_api_version`) — the Traefik chart stopped bundling them, so
   skipping this step means `providers.kubernetesGateway.enabled: true`
   fails outright with "no matches for kind Gateway".
2. **`traefik_extra_values`** — a raw YAML string for anything else the
   chart supports (see the full [values
   reference](https://github.com/traefik/traefik-helm-chart)): ports,
   `additionalArguments`, `ingressRoute.dashboard`, resource limits,
   `gateway.listeners`, whatever. It's passed as a second `-f` file, so it
   can override what the generated file sets too. Example — the default
   Gateway only accepts routes from its own namespace; to open it to every
   namespace:
   ```hcl
   traefik_extra_values = <<-YAML
     gateway:
       listeners:
         web:
           namespacePolicy:
             from: All
   YAML
   ```
3. **Edit `templates/traefik-values.yaml.tpl` directly** if something
   deserves to be a first-class, named variable rather than living in a
   blob of YAML in `terraform.tfvars` — same pattern as `service_type`.

## cert-manager

`cert-manager.tf` installs [cert-manager](https://cert-manager.io/) via its
Helm chart once Calico is up:

1. Installs Helm if it isn't already there (same `get-helm-3`/`helm_version`
   bootstrap as Traefik — each resource checks independently, so this
   works whether or not `install_traefik` is also enabled).
2. `helm repo add jetstack https://charts.jetstack.io` and
   `helm repo update`.
3. `helm upgrade --install cert-manager jetstack/cert-manager --version
   cert_manager_version -n cert_manager_namespace --create-namespace --set
   crds.enabled=true -f cert-manager-extra-values.yaml` — the modern chart
   installs its own CRDs via that flag, no separate manifest step needed.
4. Waits for both the `cert-manager` and `cert-manager-webhook` deployments
   to become available — the webhook specifically, because creating an
   Issuer or Certificate before it's up fails validation.

Set `install_cert_manager = false` to skip this. `cert_manager_extra_values`
works the same way as `traefik_extra_values` — raw YAML, passed as a `-f`
file, for anything beyond the CRD flag this project sets by default (see
the [chart's values reference](https://cert-manager.io/docs/installation/helm/#configuration)).

**This installs the controller only — no `Issuer` or `ClusterIssuer` is
created.** Which one makes sense depends entirely on how you want
certificates issued, and guessing wrong here would mean either a
non-functional issuer or one configured against the wrong domain/DNS
provider:

- **Let's Encrypt, HTTP-01 challenge** — needs a public domain with port 80
  reachable from the internet (i.e. something port-forwarded through your
  router to this cluster). Straightforward if you have that; a non-starter
  for a fully internal homelab network.
- **Let's Encrypt, DNS-01 challenge** — needs a DNS provider with an API
  cert-manager can use (Cloudflare, Route53, etc.) to create a `TXT`
  record proving domain ownership. Works without exposing anything
  publicly, so it's the common choice for homelabs that still want
  browser-trusted certs.
- **Self-signed / internal CA** — cert-manager bootstraps a `SelfSigned`
  issuer, uses it to mint a root CA `Certificate`, then a `CA` issuer
  referencing that root's secret issues certs for everything else. Nothing
  external required, but every client needs that root CA imported to trust
  it without a browser warning.

**`letsencrypt-cloudflare.tf` implements the DNS-01 + Cloudflare option**,
creating two `ClusterIssuer`s once cert-manager is up:

- `letsencrypt-staging` — `https://acme-staging-v02.api.letsencrypt.org/directory`.
  Not trusted by browsers, but has much higher rate limits — use this while
  testing so you don't hit Let's Encrypt's production rate limits from
  repeated `Certificate` requests.
- `letsencrypt-production` — `https://acme-v02.api.letsencrypt.org/directory`.
  Real, browser-trusted certs, tightly rate-limited.

Both use the same Cloudflare API token, stored as a Kubernetes `Secret`
(`cloudflare_secret_name`, default `cloudflare-api-token-secret`) in
`cert_manager_namespace` — that's where `ClusterIssuer` secret references
resolve to by default (cert-manager's `--cluster-resource-namespace`,
which this project leaves at its default of "wherever cert-manager itself
is installed"). Set `install_letsencrypt_cloudflare_issuers = false` to
skip creating these.

**Required when that's `true`:**

- `acme_email` — contact email for both ACME account registrations.
- `cloudflare_api_token` — **must be a scoped API token** (Cloudflare
  dashboard → My Profile → API Tokens → Create Token → "Edit zone DNS"
  template, scoped to the zone(s) you'll issue certs for), not the legacy
  account-wide Global API Key. Terraform refuses to plan without both of
  these set, the same way it does for `metallb_address_pool`.

To actually use an issuer once it's up, reference it from a `Certificate`
or an Ingress/IngressRoute/Gateway annotation with
`issuerRef.name: letsencrypt-staging` (or `letsencrypt-production`) and
`issuerRef.kind: ClusterIssuer` — test against staging first.

## Cluster name, pod CIDR, service CIDR

These three are rendered into `templates/kubeadm-config.yaml.tpl` (a
kubeadm `InitConfiguration` + `ClusterConfiguration` document) rather than
passed as CLI flags, via `var.cluster_name`, `var.pod_network_cidr`, and
`var.kubernetes_service_cidr`. The rendered file is pushed to
`/tmp/kubeadm-config.yaml` on the first control-plane node and consumed
with `kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs`.

The config's `apiVersion` (`kubeadm.k8s.io/<version>`) is also a variable —
`kubeadm_api_version`, defaulting to `v1beta4`. kubeadm's config schema
version is tied to the kubeadm binary version and old schemas eventually
stop being accepted entirely (not just deprecated) as kubeadm moves on. If
`kubeadm init` fails with something like:

```
error: your configuration file uses an old API spec ... Please use kubeadm
vX.Y instead and run 'kubeadm config migrate ...'
```

check `/var/log/kubeadm-init.log` on the control-plane node, then check
`kubeadm version` on the template/node to find which schema that kubeadm
actually supports, and set `kubeadm_api_version` accordingly.

## Cloud-init

Every node (control plane and worker) gets the same cloud-init identity,
driven entirely by variables — no per-node cloud-init files to maintain:

```hcl
initialization {
  user_account {
    username = var.ci_username
    password = var.ci_password
    keys     = var.ssh_public_keys
  }
  ip_config {
    ipv4 { address = "dhcp" }
  }
}
```

## kubeadm flow

1. `null_resource.kubeadm_init` SSHes into the control plane and runs
   `kubeadm init` (no `--skip-phases` for CNI — kubeadm never installs a CNI
   itself, so there's nothing to skip; just don't apply a CNI manifest
   afterwards), then captures the join command to `/tmp/kubeadm-join.sh` on
   that node.
2. `null_resource.fetch_join_command` SCPs/SSHes that file back to
   `generated/kubeadm-join.sh` next to this config.
3. `null_resource.worker_join` runs on every worker, piping the join command
   into `sudo bash`.
4. `null_resource.fetch_kubeconfig` pulls `admin.conf` back to
   `generated/kubeconfig`.

## Proxmox's self-signed certificate

Proxmox ships with a self-signed cert by default, which fails normal TLS
verification. Two ways to deal with it:

- **Quick path (what `terraform.tfvars.example` does):** set
  `proxmox_insecure = true`. This tells the `bpg/proxmox` provider to skip
  TLS certificate verification entirely for API calls — fine for a homelab,
  not something you'd want for anything internet-facing, since it also
  drops protection against a MITM on that connection.
- **Proper path:** replace Proxmox's cert with one your client machine
  actually trusts — either install a real cert (e.g. via an internal CA or
  Let's Encrypt using Proxmox's ACME integration under *Datacenter → ACME*),
  or export Proxmox's self-signed CA and add it to your system's trust
  store. Then leave `proxmox_insecure = false` (the default) and Terraform
  verifies the connection normally.

This only affects the Terraform-to-Proxmox-API connection (VM
create/clone/disk calls). It's unrelated to the SSH connections the
`kubeadm`/kube-vip provisioners make directly to the VMs, which already run
with `StrictHostKeyChecking=no` since those hosts don't exist until this
project creates them.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your Proxmox token, template, ssh keys, etc.

terraform init
terraform plan
terraform apply
```

## Sequential vs. parallel VM creation

By default, Terraform creates up to 10 resources concurrently. For the VM
clones specifically, that usually isn't a speedup — concurrent clones from
the same Proxmox template tend to contend with each other (storage locks,
the Proxmox task queue) rather than genuinely run in parallel, so
one-at-a-time is often faster in practice, not just simpler to reason
about.

There isn't a clean way to force this from inside the `.tf` files
themselves: Terraform statically rejects a resource referencing other
instances of its own type in `depends_on` (`Error: Self-referential block`)
even when the indices differ, so a self-chaining trick on the
`count`-based VM resources isn't actually possible here — anything that
looks like it works that way will fail `terraform plan` outright. The
real lever is Terraform's own `-parallelism` flag, which caps concurrency
for the whole apply. Use it directly:

```bash
terraform apply -parallelism=1
```

or via the included `Makefile`, which defaults to `-parallelism=1`:

```bash
make apply
# or, to allow some concurrency back:
make apply PARALLELISM=5
```

**Control planes before workers**: the `worker` resource has a plain
`depends_on = [proxmox_virtual_environment_vm.control_plane]` — this is
a normal cross-resource dependency (control planes and workers are
separate resource blocks), not the same self-referencing pattern that's
disallowed above, so it's fully supported. Every control-plane VM is
created before any worker VM starts, regardless of `-parallelism`.
Combined with `-parallelism=1`, the whole build becomes fully
deterministic: control planes one at a time, then workers one at a time.

This caps concurrency for the *entire* apply, not just the VM clones —
in practice that mostly affects the clone phase itself plus the handful of
addon installs that don't depend on each other (MetalLB and cert-manager,
for instance, both only depend on Calico, not on each other), since most
of the rest of the graph (kubeadm join steps, Traefik after MetalLB, etc.)
is already serialized by real `depends_on` chains regardless of this
setting.

Once applied:

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes    # Ready once Calico finishes installing (see below)
```

With `install_calico = false`, nodes show `NotReady` until you install a
CNI of your choice.

## Longhorn

`longhorn.tf` installs [Longhorn](https://longhorn.io/) via its Helm
chart, in two stages:

1. **Prerequisites, per worker** (`longhorn_prereqs`): installs
   `open-iscsi`/`iscsi-initiator-utils` (Longhorn's engine pods need
   `iscsiadm` on the host or they crashloop — this is the single most
   common Longhorn setup failure) and `nfs-common`/`nfs-utils` (enables
   Longhorn's built-in RWX/NFS support). Detects `apt-get` vs. `dnf` vs.
   `yum` rather than assuming one, and enables/starts `iscsid`.
2. **Longhorn itself**, once Calico, the prereqs, and — importantly —
   `prepare_worker_data_disk` have all finished: `helm upgrade --install
   longhorn longhorn/longhorn` with `defaultSettings.defaultReplicaCount`
   and `persistence.defaultClassReplicaCount` both set to
   `longhorn_replica_count`, then waits on the `longhorn-manager`
   DaemonSet and `longhorn-driver-deployer` Deployment rollouts.

**Why it waits on the data-disk mount specifically**: Longhorn's default
data path (`/var/lib/longhorn`) is exactly where `worker-data-disk.tf`
mounts the dedicated disk — zero path configuration needed between the
two. But if Longhorn started before that mount existed, its manager pods
would initialize a default disk on the *root filesystem* at that path
instead, and once the real disk mounted on top, that data would just be
silently shadowed underneath it. The dependency ordering prevents that.

**`longhorn_replica_count`** defaults to `min(worker_count, 3)` rather
than blindly using Longhorn's own upstream default of 3 — with fewer than
3 workers, asking for 3 replicas just means replicas piling up wherever
they fit rather than spreading across nodes, which defeats the point.
Set it explicitly to override.

Set `install_longhorn = false` to skip all of this. `longhorn_extra_values`
works the same way as the other charts' extra-values variables — raw YAML
passed as a `-f` file — for anything beyond the replica-count flags this
project sets by default.

**Not wired up**: the Longhorn UI isn't exposed through Traefik. It ships
with no built-in authentication, so exposing it means deciding on an auth
approach (Traefik BasicAuth middleware, an OAuth2 proxy, etc.) first —
worth doing deliberately rather than by default. `kubectl -n
longhorn-system port-forward svc/longhorn-frontend 8080:80` gets you the
UI locally in the meantime.

## Prometheus (kube-prometheus-stack)

`prometheus.tf` installs
[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
— Prometheus, Alertmanager, Grafana, node-exporter, and kube-state-metrics
together — via its Helm chart, once Calico (and Longhorn, if enabled) are
up. This chart bundles its own CRDs (`PrometheusRule`, `ServiceMonitor`,
etc.) in the standard Helm `crds/` convention, so unlike Calico there's no
separate manifest step — a plain `helm upgrade --install` handles it.

**Storage**: `templates/prometheus-values.yaml.tpl` wires Prometheus,
Alertmanager, and Grafana to persistent volumes on the `longhorn`
StorageClass automatically when `install_longhorn = true` (sizes via
`prometheus_storage_size`/`alertmanager_storage_size`/
`grafana_storage_size`). With `install_longhorn = false`, persistence is
left disabled entirely rather than requesting a PVC with no StorageClass
to satisfy it — which would just leave pods stuck `Pending` forever and
the `kubectl rollout status` wait timing out.

**Grafana's admin password** is auto-generated by the chart unless you set
`grafana_admin_password` explicitly. Retrieve the generated one with:

```bash
kubectl -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Set `install_prometheus = false` to skip this entirely.
`prometheus_extra_values` works the same way as the other charts'
extra-values variables — raw YAML, passed as a `-f` file — for anything
beyond storage/retention/admin-password (alerting receivers, additional
scrape configs, resource limits, etc.).

**Not wired up**: like Longhorn's UI, Grafana isn't exposed through
Traefik by default — that's a deliberate choice about auth/exposure this
project shouldn't make for you (Grafana does have its own login, unlike
Longhorn's UI, so exposing it is a lower-stakes decision, but still a
decision). `kubectl -n monitoring port-forward svc/prometheus-grafana
3000:80` gets you the UI locally in the meantime.

## prometheus-adapter (metrics.k8s.io / metrics-server replacement)

`prometheus-adapter.tf` installs
[prometheus-adapter](https://github.com/kubernetes-sigs/prometheus-adapter)
once `install_prometheus` is up. This is a real implementation of the
`metrics.k8s.io` resource-metrics API — the same API `kubectl top` and the
Horizontal Pod Autoscaler use — except it's backed by querying Prometheus
instead of talking to kubelet's summary API directly, which is what a
standalone `metrics-server` would normally do. This project never installs
`metrics-server`, so prometheus-adapter is the sole provider here — no
conflict to worry about.

It's pointed at the Service this project's own `kube-prometheus-stack`
install creates (`prometheus-kube-prometheus-prometheus` — release name
`prometheus`, per the naming this chart uses) via
`prometheus.url`/`prometheus.port`. The chart's own `rules.default: true`
(its default, left alone here) is enough on its own to serve CPU/memory
metrics — no custom PromQL required for `kubectl top` or a basic
CPU/memory-based HPA to work.

The install doesn't stop at a rollout-status check — it waits on `kubectl
top nodes` actually succeeding (up to 2 minutes), since a `Running` pod
doesn't mean the API is serving real data yet: the adapter needs at least
one relist interval (chart default 1 minute) after starting before it has
anything to report.

Requires `install_prometheus = true` (Terraform validates this and refuses
to plan otherwise) — it queries the Prometheus this project installs, not
a standalone one. `prometheus_adapter_extra_values` works the same as the
other charts' extra-values variables, for tuning `rules.resource`,
`rules.custom`, `metricsRelistInterval`, etc. beyond the defaults.

## Node labels

`node-labels.tf` applies labels to nodes once they've joined, from two
sources merged together (`node_labels` wins on any key it also sets for
that node):

1. **Automatic zone labels** (`label_zone_automatically = true`, the
   default): every node gets `zone_label_key` (default
   `topology.kubernetes.io/zone` — the documented Kubernetes convention
   for a node's failure/topology zone, so anything that already
   understands it, like pod topology spread constraints or
   topology-aware storage provisioning, picks it up with no extra config)
   set to wherever it's actually placed — `control_plane_placement`/
   `worker_placement` resolved per instance, so this is accurate now that
   placement is genuinely per-VM (see [Placing
   nodes](#placing-nodes-on-specific-proxmox-servers-and-migrating-between-them)
   above) rather than one shared value. Set `label_zone_automatically =
   false` to turn this off entirely.
2. **`node_labels`** — a map keyed by node name, each value a map of
   label-key to label-value, for anything beyond the automatic zone label:
   ```hcl
   node_labels = {
     "homelab-worker-01" = { disktype = "ssd" }
   }
   ```

Node names equal VM names (`<cluster_name>-<role>-<NN>` — see [VM
names](#vm-names)), since cloud-init sets the guest hostname from the VM
name and kubelet registers under that hostname.

For each label, this runs `kubectl label node <name> <key>=<value>
--overwrite`, with a `kubectl wait --for=create node/<name>` first in case
labeling races ahead of the node actually registering. It only depends on
every node having joined — not on Calico/MetalLB/Traefik/cert-manager,
since a `Node` object exists in the API as soon as kubelet registers,
before it's network-Ready.

This applies via `kubectl` with cluster-admin credentials, so — unlike
labels a kubelet sets on itself at join time via `--node-labels`, which
`NodeRestriction` blocks for most `kubernetes.io/`/`k8s.io/`-prefixed
labels — it works for **any** label, reserved or custom. That's exactly
why the automatic zone label above can use the real, reserved
`topology.kubernetes.io/zone` key rather than a workaround custom one.

## Limitations / things to know

- **Migration doesn't rebalance kubeadm/etcd.** `migrate = true` moves the
  VM at the Proxmox level; it has no idea a VM might be an etcd member
  or the leader kube-vip is currently ARPing from. For an HA control plane,
  migrate nodes one at a time and expect a brief blip while etcd/kube-vip
  notice and recover, rather than migrating all control planes in one
  `apply`.

- **kube-vip is ARP-mode only.** It works within a single L2 broadcast
  domain; it won't help across routed subnets, and there's no BGP mode wired
  up here. If your control-plane nodes span subnets, use a real external
  load balancer via `control_plane_endpoint_override` instead.
- **No load balancer/VIP unless you ask for one.** Without `control_plane_vip`
  or `control_plane_endpoint_override` set, `control_plane_ha = true` gives
  you three joined control planes behind a `controlPlaneEndpoint` that's
  just the first node's own IP — a single point of failure.
- **DHCP networking.** Nodes get IPs via DHCP; there's no static
  IP/reservation management. If your DHCP server doesn't hand out stable
  leases, node IPs can change between applies (the join automation re-reads
  the IP each run, so this only bites you after the cluster already exists).
- **Provisioner-based, not idempotent-by-design.** The `null_resource`
  provisioners run once when the resource is created and won't re-run kubeadm
  on `terraform apply` unless you taint them or the trigger values change.
  Destroying and recreating a worker will re-run its join automatically
  (worker `triggers` include the worker's VM id and the current join
  command).
- **Secrets in state.** `ci_password` and the Proxmox API token end up in
  Terraform state. Use a remote backend with encryption/access control for
  anything beyond a lab.
