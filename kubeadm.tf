#############################################
# Local scratch dir for generated artifacts
#############################################

resource "local_file" "generated_dir_keep" {
  filename = "${path.module}/generated/.keep"
  content  = ""
}

#############################################
# kubeadm init on the first control plane node
#############################################

resource "null_resource" "kubeadm_init" {
  triggers = {
    control_plane_id = proxmox_virtual_environment_vm.control_plane[0].id
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ip
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # Parameterized cluster name / pod CIDR / service CIDR / control-plane
  # endpoint, rendered from templates/kubeadm-config.yaml.tpl.
  provisioner "file" {
    content     = local.kubeadm_config
    destination = "/tmp/kubeadm-config.yaml"
  }

  provisioner "remote-exec" {
    inline = concat(
      ["set -euo pipefail"],
      local.use_kube_vip ? [
        "sudo ctr image pull ghcr.io/kube-vip/kube-vip:${var.kube_vip_version}",
        "sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${var.kube_vip_version} vip /kube-vip manifest pod --interface ${var.kube_vip_interface} --address ${var.control_plane_vip} --controlplane --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml",
      ] : [],
      [
        "sudo kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs 2>&1 | sudo tee /var/log/kubeadm-init.log",
        "mkdir -p $HOME/.kube",
        "sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config",
        "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
        "sudo kubeadm token create --print-join-command | sudo tee /tmp/kubeadm-join-worker.sh",
        # No control-plane join command generated here anymore -- kubeadm's
        # uploaded certs (from --upload-certs above) have a hard 2-hour
        # TTL, and generating this once early can expire before an
        # additional control plane actually gets around to joining on a
        # slower/more sequential apply. control_plane_join below
        # regenerates a fresh one immediately before each additional
        # control plane joins instead.
      ]
    )
  }
}

#############################################
# Pull the worker join command back to the machine running Terraform
#############################################

resource "null_resource" "fetch_join_commands" {
  depends_on = [null_resource.kubeadm_init, local_file.generated_dir_keep]

  triggers = {
    control_plane_id = proxmox_virtual_environment_vm.control_plane[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ${var.ssh_private_key_path} \
        ${var.ci_username}@${local.control_plane_ip} \
        'sudo cat /tmp/kubeadm-join-worker.sh' > ${local.worker_join_command_file}
    EOT
  }
}

data "local_file" "worker_join_command" {
  depends_on = [null_resource.fetch_join_commands]
  filename   = local.worker_join_command_file
}

#############################################
# Fetch kubeconfig locally (control plane admin.conf)
#############################################

resource "null_resource" "fetch_kubeconfig" {
  depends_on = [null_resource.kubeadm_init]

  triggers = {
    control_plane_id = proxmox_virtual_environment_vm.control_plane[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ${var.ssh_private_key_path} \
        ${var.ci_username}@${local.control_plane_ip} \
        'cat $HOME/.kube/config' > ${path.module}/generated/kubeconfig
    EOT
  }
}

#############################################
# Join additional control-plane nodes (only when control_plane_ha = true)
#############################################

# Regenerates a fresh join command + certificate-key once, shared by every
# additional control plane, immediately before they join -- rather than
# reusing one generated once early in the apply (kubeadm_init). kubeadm's
# uploaded certs default to a 2-hour TTL -- with sequential VM creation and
# a control-planes-then-workers build order, the overall apply can easily
# take long enough that a value generated at kubeadm_init time has already
# expired by the time a later control plane gets here.
#
# This is deliberately ONE shared resource, not one per extra control
# plane: 'kubeadm init phase upload-certs --upload-certs' overwrites a
# single cluster-wide Secret each time it's called, so running it
# independently per instance races -- whichever ran last silently
# invalidates the cert-key any earlier instance already fetched. The
# cert-key isn't single-use; it's valid for any node joining within its
# TTL window, so one shared value for all of them is correct, not just
# simpler.
resource "null_resource" "fresh_control_plane_join_command" {
  count = local.control_plane_count > 1 ? 1 : 0

  depends_on = [null_resource.kubeadm_init]

  triggers = {
    # Tied to every extra control-plane VM's identity combined: regenerate
    # if any of them are newly created or rebuilt, but never on an
    # unrelated later apply once they've all already joined, which would
    # just fail kubeadm's own preflight checks.
    control_plane_ids = join(",", [for i in range(1, local.control_plane_count) : proxmox_virtual_environment_vm.control_plane[i].id])
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ${var.ssh_private_key_path} \
        ${var.ci_username}@${local.control_plane_ip} \
        'set -euo pipefail; sudo kubeadm token create --print-join-command > /tmp/kubeadm-join-worker-fresh.sh; CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1); echo "$(cat /tmp/kubeadm-join-worker-fresh.sh) --control-plane --certificate-key $CERT_KEY"' \
        > ${path.module}/generated/kubeadm-join-control-plane-fresh.sh
    EOT
  }
}

data "local_file" "control_plane_join_command_fresh" {
  count      = local.control_plane_count > 1 ? 1 : 0
  depends_on = [null_resource.fresh_control_plane_join_command]
  filename   = "${path.module}/generated/kubeadm-join-control-plane-fresh.sh"
}

resource "null_resource" "control_plane_join" {
  count = local.control_plane_count > 1 ? local.control_plane_count - 1 : 0

  depends_on = [data.local_file.control_plane_join_command_fresh]

  triggers = {
    # Deliberately does NOT include the join command's content. That value
    # is shared across every extra control plane (see the comment above),
    # so if it changed too, EVERY instance referencing it would be forced
    # to replace -- including ones that already joined successfully in an
    # earlier apply, which would then fail kubeadm's own preflight checks
    # trying to join a second time. Keying only on this instance's own VM
    # id means a targeted retry of one control plane's join never disturbs
    # another one that's already done.
    node_id = proxmox_virtual_environment_vm.control_plane[count.index + 1].id
  }

  connection {
    type        = "ssh"
    host        = local.control_plane_ips[count.index + 1]
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = concat(
      ["set -euo pipefail"],
      local.use_kube_vip ? [
        "sudo ctr image pull ghcr.io/kube-vip/kube-vip:${var.kube_vip_version}",
        "sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${var.kube_vip_version} vip /kube-vip manifest pod --interface ${var.kube_vip_interface} --address ${var.control_plane_vip} --controlplane --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml",
      ] : [],
      [
        # Idempotency guard: if this node has already been kubeadm-joined
        # (kubelet.conf exists), skip rather than attempt the join command
        # again -- kubeadm doesn't support re-joining an already-joined
        # node, so a stray retry (e.g. re-tainting fresh_control_plane_join_command
        # for a different control plane) would otherwise fail hard on a
        # node that's actually fine.
        "if sudo test -f /etc/kubernetes/kubelet.conf; then echo 'Already joined -- skipping'; else echo '${chomp(data.local_file.control_plane_join_command_fresh[0].content)}' | sudo bash; fi",
      ]
    )
  }
}

#############################################
# Join each worker automatically, via sudo
#############################################

resource "null_resource" "worker_join" {
  count = var.worker_count

  depends_on = [data.local_file.worker_join_command]

  triggers = {
    # Deliberately does NOT include the join command's content -- it's a
    # single value shared by every worker (see control_plane_join's
    # comment for why that matters), so if it changed too, every worker
    # referencing it would be forced to replace, including ones that
    # already joined successfully in an earlier apply. Keying only on this
    # instance's own VM id means retrying one worker's join never disturbs
    # another one that's already done.
    worker_id = proxmox_virtual_environment_vm.worker[count.index].id
  }

  connection {
    type        = "ssh"
    host        = local.worker_ips[count.index]
    user        = var.ci_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      # Idempotency guard: if this node has already been kubeadm-joined
      # (kubelet.conf exists), skip rather than attempt the join command
      # again -- kubeadm doesn't support re-joining an already-joined
      # node, so a stray retry (e.g. re-tainting this resource, or a
      # shared trigger changing for an unrelated reason) would otherwise
      # fail hard on a node that's actually fine.
      "if sudo test -f /etc/kubernetes/kubelet.conf; then echo 'Already joined -- skipping'; else echo '${chomp(data.local_file.worker_join_command.content)}' | sudo bash; fi",
    ]
  }
}
