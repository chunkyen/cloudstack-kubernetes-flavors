terraform {
  required_providers {
    cloudstack = {
      source  = "cloudstack/cloudstack"
      version = "~> 0.6"
    }
  }
}

provider "cloudstack" {
  # Configure via environment variables:
  #   CLOUDSTACK_API_URL  - CloudStack API endpoint
  #   CLOUDSTACK_API_KEY  - CloudStack API key
  #   CLOUDSTACK_SECRET_KEY - CloudStack secret key
}

# ──────────────────────────────────────────────
# Network
# ──────────────────────────────────────────────

resource "cloudstack_network" "talos" {
  name              = "${var.cluster_name}-net"
  display_text      = "Isolated network for ${var.cluster_name}"
  cidr              = var.network_cidr
  gateway           = var.network_gateway
  network_offering  = var.network_offering_id
  zone              = var.zone_id
}

# ──────────────────────────────────────────────
# Public IP — use pre-allocated or create new
# ──────────────────────────────────────────────

data "cloudstack_ipaddress" "existing" {
  count = var.public_ip_id != "" ? 1 : 0
  filter {
    name  = "id"
    value = var.public_ip_id
  }
}

resource "cloudstack_ipaddress" "talos" {
  count      = var.public_ip_id != "" ? 0 : 1
  zone       = var.zone_id
  network_id = cloudstack_network.talos.id
}

locals {
  public_ip_id = var.public_ip_id != "" ? var.public_ip_id : cloudstack_ipaddress.talos[0].id
  public_ip    = var.public_ip_id != "" ? data.cloudstack_ipaddress.existing[0].ip_address : cloudstack_ipaddress.talos[0].ip_address
  # Talos API ports: 50000 to 50000 + control_plane_count - 1
  talos_api_port_start = 50000
  talos_api_port_end   = 50000 + var.control_plane_count - 1
}

# ──────────────────────────────────────────────
# Load Balancer — Kubernetes API (6443)
# ──────────────────────────────────────────────

resource "cloudstack_loadbalancer_rule" "k8s_api" {
  name          = "${var.cluster_name}-k8s-api"
  algorithm     = "roundrobin"
  private_port  = 6443
  public_port   = 6443
  ip_address_id = local.public_ip_id
  network_id    = cloudstack_network.talos.id
  member_ids    = cloudstack_instance.control_plane[*].id
  cidrlist      = ["0.0.0.0/0"]
}

# ──────────────────────────────────────────────
# Firewall Rules
# ──────────────────────────────────────────────

resource "cloudstack_firewall" "k8s_api" {
  ip_address_id = local.public_ip_id

  rule {
    protocol  = "tcp"
    ports     = ["6443"]
    cidr_list = ["0.0.0.0/0"]
  }
}

resource "cloudstack_firewall" "talos_api" {
  ip_address_id = local.public_ip_id

  rule {
    protocol  = "tcp"
    ports     = ["${local.talos_api_port_start}-${local.talos_api_port_end}"]
    cidr_list = ["0.0.0.0/0"]
  }
}

# ──────────────────────────────────────────────
# Control Plane VMs
# ──────────────────────────────────────────────

resource "cloudstack_instance" "control_plane" {
  count            = var.control_plane_count
  name             = "${var.cluster_name}-cp-${count.index + 1}"
  display_name     = "${var.cluster_name}-cp-${count.index + 1}"
  service_offering = var.control_plane_offering_id
  template         = var.template_id
  zone             = var.zone_id
  network_id       = cloudstack_network.talos.id
  user_data        = var.control_plane_userdata
  root_disk_size   = 20

  # ⚠️ Critical: Talos requires host-passthrough CPU mode
  details = {
    "guest.cpu.mode" = "host-passthrough"
  }
}

# ──────────────────────────────────────────────
# Port Forwarding for talosctl API (port 50000)
# ──────────────────────────────────────────────

resource "cloudstack_port_forward" "talos_api" {
  count         = var.control_plane_count
  ip_address_id = local.public_ip_id

  forward {
    private_port  = 50000
    public_port   = 50000 + count.index
    protocol      = "tcp"
    virtual_machine_id = cloudstack_instance.control_plane[count.index].id
  }
}

# ──────────────────────────────────────────────
# Worker VMs
# ──────────────────────────────────────────────

resource "cloudstack_instance" "worker" {
  count            = var.worker_count
  name             = "${var.cluster_name}-worker-${count.index + 1}"
  display_name     = "${var.cluster_name}-worker-${count.index + 1}"
  service_offering = var.worker_offering_id
  template         = var.template_id
  zone             = var.zone_id
  network_id       = cloudstack_network.talos.id
  user_data        = var.worker_userdata
  root_disk_size   = 40

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
  value       = local.public_ip
  description = "Public IP for the Kubernetes API endpoint"
}

output "public_ip_id" {
  value       = local.public_ip_id
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
  value       = "${local.public_ip}:6443"
  description = "Kubernetes API endpoint"
}

output "talos_api_endpoints" {
  value = [
    for i in range(var.control_plane_count) :
    "${local.public_ip}:${50000 + i}"
  ]
  description = "Talos API endpoints (port 50000+ for each CP node)"
}
