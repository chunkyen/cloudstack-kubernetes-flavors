terraform {
  required_providers {
    cloudstack = {
      source  = "apache/cloudstack"
      version = "~> 0.10"
    }
  }
}

provider "cloudstack" {
  # Configure via environment variables:
  #   CLOUDSTACK_API_URL  - CloudStack API endpoint (e.g., http://192.168.200.1:8080/client/api)
  #   CLOUDSTACK_API_KEY  - CloudStack API key
  #   CLOUDSTACK_SECRET_KEY - CloudStack secret key
  # Or via provider config block:
  #   api_url  = "http://..."
  #   api_key  = "..."
  #   secret_key = "..."
}

# ──────────────────────────────────────────────
# Network
# ──────────────────────────────────────────────

resource "cloudstack_network" "talos" {
  name               = "${var.cluster_name}-net"
  display_text       = "Isolated network for ${var.cluster_name}"
  cidr               = var.network_cidr
  gateway            = var.network_gateway
  network_offering   = var.network_offering_id
  zone_id            = var.zone_id
}

# ──────────────────────────────────────────────
# Public IP
# ──────────────────────────────────────────────

resource "cloudstack_ipaddress" "talos" {
  zone_id    = var.zone_id
  network_id = cloudstack_network.talos.id
}

# ──────────────────────────────────────────────
# Load Balancer — Kubernetes API (6443)
# ──────────────────────────────────────────────

resource "cloudstack_lb_rule" "k8s_api" {
  name               = "${var.cluster_name}-k8s-api"
  algorithm          = "roundrobin"
  private_port       = 6443
  public_port        = 6443
  public_ip_id       = cloudstack_ipaddress.talos.id
  network_id         = cloudstack_network.talos.id
}

# ──────────────────────────────────────────────
# Control Plane VMs
# ──────────────────────────────────────────────

resource "cloudstack_instance" "control_plane" {
  count              = var.control_plane_count
  name               = "${var.cluster_name}-cp-${count.index + 1}"
  display_name       = "${var.cluster_name}-cp-${count.index + 1}"
  service_offering   = var.control_plane_offering_id
  template           = var.template_id
  zone_id            = var.zone_id
  network_id         = cloudstack_network.talos.id
  user_data          = var.control_plane_userdata
  root_disk_size     = 20

  # ⚠️ Critical: Talos requires host-passthrough CPU mode
  details = {
    "guest.cpu.mode" = "host-passthrough"
  }
}

# Assign control plane VMs to the load balancer
resource "cloudstack_lb_rule_member" "control_plane" {
  count        = var.control_plane_count
  lb_rule_id   = cloudstack_lb_rule.k8s_api.id
  instance_id  = cloudstack_instance.control_plane[count.index].id
}

# Port forwarding for talosctl API (port 50000) — one per CP node
resource "cloudstack_port_forward" "talos_api" {
  count              = var.control_plane_count
  ip_address_id      = cloudstack_ipaddress.talos.id
  private_port       = 50000
  public_port        = 50000 + count.index
  protocol           = "tcp"
  virtual_machine_id = cloudstack_instance.control_plane[count.index].id
  network_id         = cloudstack_network.talos.id
}

# ──────────────────────────────────────────────
# Worker VMs
# ──────────────────────────────────────────────

resource "cloudstack_instance" "worker" {
  count              = var.worker_count
  name               = "${var.cluster_name}-worker-${count.index + 1}"
  display_name       = "${var.cluster_name}-worker-${count.index + 1}"
  service_offering   = var.worker_offering_id
  template           = var.template_id
  zone_id            = var.zone_id
  network_id         = cloudstack_network.talos.id
  user_data          = var.worker_userdata
  root_disk_size     = 40

  # ⚠️ Critical: Talos requires host-passthrough CPU mode
  details = {
    "guest.cpu.mode" = "host-passthrough"
  }
}

# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────

output "network_id" {
  value       = cloudstack_network.talos.id
  description = "ID of the created isolated network"
}

output "public_ip" {
  value       = cloudstack_ipaddress.talos.ip_address
  description = "Public IP for the Kubernetes API endpoint"
}

output "public_ip_id" {
  value       = cloudstack_ipaddress.talos.id
  description = "ID of the allocated public IP"
}

output "control_plane_ips" {
  value       = cloudstack_instance.control_plane[*].ip_address
  description = "Private IPs of control plane VMs"
}

output "worker_ips" {
  value       = cloudstack_instance.worker[*].ip_address
  description = "Private IPs of worker VMs"
}

output "k8s_api_endpoint" {
  value       = "${cloudstack_ipaddress.talos.ip_address}:6443"
  description = "Kubernetes API endpoint (use this for talosctl gen config and kubeconfig)"
}

output "talos_api_endpoints" {
  value = [
    for i in range(var.control_plane_count) :
    "${cloudstack_ipaddress.talos.ip_address}:${50000 + i}"
  ]
  description = "Talos API endpoints (port 50000+ for each CP node)"
}
