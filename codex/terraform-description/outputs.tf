output "load_balancer_ip" {
  description = "Global external IP address for the HTTP load balancer."
  value       = google_compute_global_address.lb.address
}

output "load_balancer_url" {
  description = "HTTP URL for the app service behind the load balancer."
  value       = "http://${google_compute_global_address.lb.address}"
}

output "app_instance_group" {
  description = "Self-managed instance group attached to the load balancer."
  value       = google_compute_instance_group.app.name
}

output "app_instance_names" {
  description = "App instances registered in the self-managed instance group."
  value       = google_compute_instance.app[*].name
}

output "db_internal_ip" {
  description = "Private IP address for the db instance."
  value       = google_compute_instance.db.network_interface[0].network_ip
}

output "monitor_internal_ip" {
  description = "Private IP address for the monitor instance."
  value       = google_compute_instance.monitor.network_interface[0].network_ip
}

output "cloud_function_uri" {
  description = "Cloud Functions Gen2 HTTPS endpoint."
  value       = google_cloudfunctions2_function.http.service_config[0].uri
}

output "function_source_bucket" {
  description = "GCS bucket that stores the Cloud Function source archive."
  value       = google_storage_bucket.function_source.name
}
