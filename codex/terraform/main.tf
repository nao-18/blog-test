locals {
  app_port      = 8080
  function_name = "${var.name_prefix}-gemini-enterprise-hook"

  labels = merge(
    {
      managed_by = "terraform"
      stack      = var.name_prefix
    },
    var.labels,
  )

  required_services = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
  ])

  #   app_startup_script = <<-EOT
  #     #!/bin/bash
  #     set -euo pipefail
  #
  #     mkdir -p /opt/dialog-app
  #     cat >/opt/dialog-app/server.py <<'PY'
  #     from http.server import BaseHTTPRequestHandler, HTTPServer
  #     import json
  #     import os
  #
  #
  #     class Handler(BaseHTTPRequestHandler):
  #         def _send(self, status, payload):
  #             body = json.dumps(payload).encode("utf-8") + b"\n"
  #             self.send_response(status)
  #             self.send_header("Content-Type", "application/json")
  #             self.send_header("Content-Length", str(len(body)))
  #             self.end_headers()
  #             self.wfile.write(body)
  #
  #         def do_GET(self):
  #             if self.path.startswith("/healthz"):
  #                 self._send(200, {"status": "ok"})
  #                 return
  #             self._send(200, {"service": "app", "instance": os.uname().nodename})
  #
  #
  #     HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
  #     PY
  #
  #     cat >/etc/systemd/system/dialog-app.service <<'SERVICE'
  #     [Unit]
  #     Description=Dialog sample app
  #     After=network-online.target
  #     Wants=network-online.target
  #
  #     [Service]
  #     ExecStart=/usr/bin/python3 /opt/dialog-app/server.py
  #     Restart=always
  #     RestartSec=5
  #
  #     [Install]
  #     WantedBy=multi-user.target
  #     SERVICE
  #
  #     systemctl daemon-reload
  #     systemctl enable --now dialog-app.service
  #   EOT
}

# resource "google_project_service" "required" {
#   for_each = local.required_services
#
#   project            = var.project_id
#   service            = each.value
#   disable_on_destroy = false
# }

data "google_compute_image" "rocky_linux" {
  family  = "rocky-linux-10"
  project = "rocky-linux-cloud"

  # depends_on = [
  #   google_project_service.required["compute.googleapis.com"],
  # ]
}

# todo あとで帰る
resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-blog-vpc"
  auto_create_subnetworks = false

  # depends_on = [
  #   google_project_service.required["compute.googleapis.com"],
  # ]
}

resource "google_compute_subnetwork" "main" {
  name                     = "${var.name_prefix}-subnet"
  ip_cidr_range            = var.subnet_cidr
  network                  = google_compute_network.main.id
  region                   = var.region
  private_ip_google_access = true
}

resource "google_compute_firewall" "allow_internal" {
  name    = "${var.name_prefix}-allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = [var.subnet_cidr]
}

resource "google_compute_firewall" "allow_lb_health_checks" {
  name    = "${var.name_prefix}-allow-lb-health-checks"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = [tostring(local.app_port)]
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  target_tags = ["${var.name_prefix}-app"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.name_prefix}-allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_ranges
  target_tags   = ["${var.name_prefix}-vm"]
}

resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "${var.name_prefix} Compute Engine service account"

  # depends_on = [
  #   google_project_service.required["iam.googleapis.com"],
  # ]
}

resource "google_compute_health_check" "app" {
  name                = "${var.name_prefix}-app-health"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = local.app_port
    request_path = "/healthz"
  }
}

resource "google_compute_address" "app" {
  name   = "${var.name_prefix}-app-ip"
  region = var.region
}

resource "google_compute_instance" "app" {
  name         = "${var.name_prefix}-app"
  machine_type = var.app_machine_type
  zone         = var.zone
  tags         = ["${var.name_prefix}-app", "${var.name_prefix}-vm"]
  labels       = merge(local.labels, { component = "app" })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.rocky_linux.self_link
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      nat_ip = google_compute_address.app.address
    }
  }

  # metadata_startup_script = local.app_startup_script

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_address" "db" {
  name   = "${var.name_prefix}-db-ip"
  region = var.region
}

resource "google_compute_instance" "db" {
  name         = "${var.name_prefix}-db"
  machine_type = var.db_machine_type
  zone         = var.zone
  tags         = ["${var.name_prefix}-db", "${var.name_prefix}-vm"]
  labels       = merge(local.labels, { component = "db" })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.rocky_linux.self_link
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      nat_ip = google_compute_address.db.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_address" "monitor" {
  name   = "${var.name_prefix}-monitor-ip"
  region = var.region
}

resource "google_compute_instance" "monitor" {
  name         = "${var.name_prefix}-monitor"
  machine_type = var.monitor_machine_type
  zone         = var.zone
  tags         = ["${var.name_prefix}-monitor", "${var.name_prefix}-vm"]
  labels       = merge(local.labels, { component = "monitor" })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.rocky_linux.self_link
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      nat_ip = google_compute_address.monitor.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
}