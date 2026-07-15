variable "zone_id" {
  description = "CloudStack zone ID"
  type        = string
}

variable "template_id" {
  description = "Talos CloudStack image template ID"
  type        = string
}

variable "network_offering_id" {
  description = "Network offering ID (must be Kubernetes service offering with egressdefaultpolicy=true)"
  type        = string
}

variable "control_plane_offering_id" {
  description = "Service offering ID for control plane VMs (e.g., kube control)"
  type        = string
}

variable "worker_offering_id" {
  description = "Service offering ID for worker VMs (e.g., kube worker1)"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name used for resource naming"
  type        = string
  default     = "talos-cluster"
}

variable "network_cidr" {
  description = "CIDR for the isolated network"
  type        = string
  default     = "10.22.2.0/24"
}

variable "network_gateway" {
  description = "Gateway for the isolated network"
  type        = string
  default     = "10.22.2.1"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (must be odd)"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 1
}

variable "control_plane_userdata" {
  description = "Base64-encoded controlplane.yaml from talosctl gen config"
  type        = string
  sensitive   = true
}

variable "worker_userdata" {
  description = "Base64-encoded worker.yaml from talosctl gen config"
  type        = string
  sensitive   = true
}

variable "public_ip_id" {
  description = "Optional: pre-allocated public IP ID. If empty, a new IP is allocated."
  type        = string
  default     = ""
}
