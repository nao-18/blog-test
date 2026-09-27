variable "project_id" {
  description = "GCP project ID where the infrastructure will be created."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources."
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP zone for single-zone Compute Engine instances."
  type        = string
  default     = "asia-northeast1-a"
}

variable "name_prefix" {
  description = "Prefix used for resource names. Use lower-case letters, numbers, and hyphens."
  type        = string
  default     = "dialog"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,18}[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix must be 1-20 characters and use lower-case letters, numbers, and hyphens."
  }
}

variable "subnet_cidr" {
  description = "CIDR range for the private subnet used by the VMs."
  type        = string
  default     = "10.10.0.0/24"
}

variable "allowed_ssh_ranges" {
  description = "Optional CIDR ranges that can SSH to the VMs. Empty by default."
  type        = list(string)
  default     = []
}

variable "app_instance_count" {
  description = "Number of app instances behind the load balancer."
  type        = number
  default     = 2

  validation {
    condition     = var.app_instance_count >= 1
    error_message = "app_instance_count must be at least 1."
  }
}

variable "app_machine_type" {
  description = "Machine type for app instances."
  type        = string
  default     = "e2-micro"
}

variable "db_machine_type" {
  description = "Machine type for the db instance."
  type        = string
  default     = "e2-micro"
}

variable "monitor_machine_type" {
  description = "Machine type for the monitor instance."
  type        = string
  default     = "e2-micro"
}

variable "function_runtime" {
  description = "Runtime for the Cloud Functions Gen2 HTTP function."
  type        = string
  default     = "python312"
}

variable "function_memory" {
  description = "Memory allocated to the Cloud Function."
  type        = string
  default     = "256M"
}

variable "function_timeout_seconds" {
  description = "Cloud Function timeout in seconds."
  type        = number
  default     = 60
}

variable "function_max_instance_count" {
  description = "Maximum number of Cloud Function instances."
  type        = number
  default     = 1
}

variable "allow_unauthenticated_function" {
  description = "Whether to allow public unauthenticated invocation of the Cloud Function."
  type        = bool
  default     = true
}

variable "force_destroy_buckets" {
  description = "Whether Terraform can delete non-empty buckets it manages."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional labels to attach to supported resources."
  type        = map(string)
  default     = {}
}
