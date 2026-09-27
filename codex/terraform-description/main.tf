locals {
  # アプリケーションが HTTP リクエストを受け付けるポート番号です。
  app_port = 8080

  # 各リソースに共通で付与するラベルと、利用者が追加するラベルを結合します。
  labels = merge(
    {
      # Terraform 管理のリソースであることを示すラベルです。
      managed_by = "terraform"
      # このスタックを識別するためのラベルです。
      stack = var.name_prefix
    },
    # variables.tf から渡された追加ラベルです。
    var.labels,
  )

  # Cloud Function のソースコードを格納する GCS バケット名の接頭辞です。
  bucket_prefix = substr(lower("${var.project_id}-${var.name_prefix}-gcf-src"), 0, 50)

  # この構成で必要になる Google Cloud API の一覧です。
  required_services = toset([
    # Cloud Functions のビルド成果物を保管する Artifact Registry API です。
    "artifactregistry.googleapis.com",
    # Cloud Functions のビルドに利用する Cloud Build API です。
    "cloudbuild.googleapis.com",
    # Cloud Functions Gen2 を作成するための API です。
    "cloudfunctions.googleapis.com",
    # Compute Engine とロードバランサーを作成するための API です。
    "compute.googleapis.com",
    # サービスアカウントを作成するための IAM API です。
    "iam.googleapis.com",
    # ログ収集に利用する Cloud Logging API です。
    "logging.googleapis.com",
    # Cloud Functions Gen2 の実行基盤である Cloud Run API です。
    "run.googleapis.com",
    # Cloud Function のソースアーカイブを保存するための Cloud Storage API です。
    "storage.googleapis.com",
  ])

  # app VM の初回起動時に実行し、簡易 HTTP サーバーを systemd サービスとして登録するスクリプトです。
  app_startup_script = <<-EOT
    #!/bin/bash
    set -euo pipefail

    mkdir -p /opt/dialog-app
    cat >/opt/dialog-app/server.py <<'PY'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import json
    import os


    class Handler(BaseHTTPRequestHandler):
        def _send(self, status, payload):
            body = json.dumps(payload).encode("utf-8") + b"\n"
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.startswith("/healthz"):
                self._send(200, {"status": "ok"})
                return
            self._send(200, {"service": "app", "instance": os.uname().nodename})


    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY

    cat >/etc/systemd/system/dialog-app.service <<'SERVICE'
    [Unit]
    Description=Dialog sample app
    After=network-online.target
    Wants=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/dialog-app/server.py
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable --now dialog-app.service
  EOT
}

resource "google_project_service" "required" {
  # required_services の各 API を 1 つずつ有効化します。
  for_each = local.required_services

  # API を有効化する対象の GCP プロジェクト ID です。
  project = var.project_id
  # 有効化する Google Cloud API のサービス名です。
  service = each.value
  # Terraform destroy 時に API 自体は無効化しない設定です。
  disable_on_destroy = false
  # 任意: 依存するサービスまでまとめて無効化しない設定です。
  disable_dependent_services = false
}

resource "random_id" "bucket_suffix" {
  # バケット名の重複を避けるために生成するランダム値のバイト数です。
  byte_length = 4
  # 任意: この値が変わるとランダム ID を再生成するためのトリガーです。
  keepers = {}
  # 任意: 生成される ID の先頭に付ける文字列です。空文字のため実質的な接頭辞はありません。
  prefix = ""
}

data "google_compute_image" "debian" {
  # VM のブートディスクに利用する OS イメージファミリーです。
  family = "debian-12"
  # OS イメージを取得する Google Cloud プロジェクトです。
  project = "debian-cloud"

  # Compute Engine API が有効化された後にイメージを参照します。
  depends_on = [
    google_project_service.required["compute.googleapis.com"],
  ]
}

resource "google_compute_network" "main" {
  # 作成する VPC ネットワークの名前です。
  name = "${var.name_prefix}-vpc"
  # 任意: VPC の用途を説明するテキストです。
  description = "${var.name_prefix} application VPC"
  # 自動サブネットを作成せず、明示したサブネットだけを利用します。
  auto_create_subnetworks = false
  # 任意: 動的ルーティングをリージョン内に限定します。
  routing_mode = "REGIONAL"
  # 任意: デフォルトルートは削除せず、通常の外向き通信経路を残します。
  delete_default_routes_on_create = false

  # Compute Engine API が有効化された後に VPC を作成します。
  depends_on = [
    google_project_service.required["compute.googleapis.com"],
  ]
}

resource "google_compute_subnetwork" "main" {
  # 作成するサブネットの名前です。
  name = "${var.name_prefix}-subnet"
  # 任意: サブネットの用途を説明するテキストです。
  description = "${var.name_prefix} private subnet"
  # サブネットに割り当てる IPv4 CIDR レンジです。
  ip_cidr_range = var.subnet_cidr
  # サブネットを所属させる VPC ネットワークです。
  network = google_compute_network.main.id
  # サブネットを作成するリージョンです。
  region = var.region
  # 外部 IP を持たない VM から Google API へプライベート経路でアクセスできるようにします。
  private_ip_google_access = true
  # 任意: 通常の VM 用サブネットとして利用します。
  purpose = "PRIVATE"
  # 任意: IPv4 のみを利用するサブネットとして作成します。
  stack_type = "IPV4_ONLY"
}

resource "google_compute_firewall" "allow_internal" {
  # VPC 内部通信を許可するファイアウォールルール名です。
  name = "${var.name_prefix}-allow-internal"
  # このファイアウォールルールを適用する VPC ネットワークです。
  network = google_compute_network.main.name
  # 任意: ファイアウォールルールの用途を説明するテキストです。
  description = "Allow internal traffic inside ${var.name_prefix} subnet"
  # 任意: 受信方向の通信に適用します。
  direction = "INGRESS"
  # 任意: ルールの優先度です。数値が小さいほど優先されます。
  priority = 1000
  # 任意: false のため、このルールを有効にします。
  disabled = false

  # ICMP 通信を許可します。
  allow {
    # 許可するプロトコルです。
    protocol = "icmp"
  }

  # TCP 通信を許可します。
  allow {
    # 許可するプロトコルです。
    protocol = "tcp"
    # 許可する TCP ポート範囲です。
    ports = ["0-65535"]
  }

  # UDP 通信を許可します。
  allow {
    # 許可するプロトコルです。
    protocol = "udp"
    # 許可する UDP ポート範囲です。
    ports = ["0-65535"]
  }

  # 通信元として許可する CIDR レンジです。
  source_ranges = [var.subnet_cidr]
}

resource "google_compute_firewall" "allow_lb_health_checks" {
  # ロードバランサーのヘルスチェック通信を許可するファイアウォールルール名です。
  name = "${var.name_prefix}-allow-lb-health-checks"
  # このファイアウォールルールを適用する VPC ネットワークです。
  network = google_compute_network.main.name
  # 任意: ファイアウォールルールの用途を説明するテキストです。
  description = "Allow load balancer health checks to app instances"
  # 任意: 受信方向の通信に適用します。
  direction = "INGRESS"
  # 任意: ルールの優先度です。数値が小さいほど優先されます。
  priority = 1000
  # 任意: false のため、このルールを有効にします。
  disabled = false

  # アプリケーションポートへの TCP 通信を許可します。
  allow {
    # 許可するプロトコルです。
    protocol = "tcp"
    # ヘルスチェックが接続するアプリケーションポートです。
    ports = [tostring(local.app_port)]
  }

  # Google Cloud HTTP(S) Load Balancing のヘルスチェック送信元レンジです。
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  # app タグを持つ VM だけにこのルールを適用します。
  target_tags = ["${var.name_prefix}-app"]
}

resource "google_compute_firewall" "allow_ssh" {
  # SSH 許可レンジが指定された場合だけ、このファイアウォールルールを作成します。
  count = length(var.allowed_ssh_ranges) > 0 ? 1 : 0

  # SSH 通信を許可するファイアウォールルール名です。
  name = "${var.name_prefix}-allow-ssh"
  # このファイアウォールルールを適用する VPC ネットワークです。
  network = google_compute_network.main.name
  # 任意: ファイアウォールルールの用途を説明するテキストです。
  description = "Allow SSH to VM instances from configured ranges"
  # 任意: 受信方向の通信に適用します。
  direction = "INGRESS"
  # 任意: ルールの優先度です。数値が小さいほど優先されます。
  priority = 1000
  # 任意: false のため、このルールを有効にします。
  disabled = false

  # SSH 用の TCP 22 番ポートを許可します。
  allow {
    # 許可するプロトコルです。
    protocol = "tcp"
    # SSH が利用するポート番号です。
    ports = ["22"]
  }

  # SSH 接続を許可する送信元 CIDR レンジです。
  source_ranges = var.allowed_ssh_ranges
  # vm タグを持つ VM だけにこのルールを適用します。
  target_tags = ["${var.name_prefix}-vm"]
}

resource "google_service_account" "vm" {
  # VM が利用するサービスアカウント ID です。
  account_id = "${var.name_prefix}-vm"
  # Google Cloud コンソールなどで表示されるサービスアカウント名です。
  display_name = "${var.name_prefix} Compute Engine service account"
  # 任意: サービスアカウントの用途を説明するテキストです。
  description = "Service account used by ${var.name_prefix} Compute Engine instances"
  # 任意: false のため、サービスアカウントを有効な状態で作成します。
  disabled = false

  # IAM API が有効化された後にサービスアカウントを作成します。
  depends_on = [
    google_project_service.required["iam.googleapis.com"],
  ]
}

resource "google_service_account" "function" {
  # Cloud Function が利用するサービスアカウント ID です。
  account_id = "${var.name_prefix}-function"
  # Google Cloud コンソールなどで表示されるサービスアカウント名です。
  display_name = "${var.name_prefix} Cloud Function service account"
  # 任意: サービスアカウントの用途を説明するテキストです。
  description = "Service account used by ${var.name_prefix} Cloud Function"
  # 任意: false のため、サービスアカウントを有効な状態で作成します。
  disabled = false

  # IAM API が有効化された後にサービスアカウントを作成します。
  depends_on = [
    google_project_service.required["iam.googleapis.com"],
  ]
}

resource "google_compute_health_check" "app" {
  # アプリケーション VM の正常性を確認するヘルスチェック名です。
  name = "${var.name_prefix}-app-health"
  # 任意: ヘルスチェックの用途を説明するテキストです。
  description = "Health check for ${var.name_prefix} app instances"
  # ヘルスチェックの実行間隔です。
  check_interval_sec = 5
  # ヘルスチェック 1 回あたりのタイムアウト秒数です。
  timeout_sec = 5
  # 正常と判断するまでに必要な連続成功回数です。
  healthy_threshold = 2
  # 異常と判断するまでに必要な連続失敗回数です。
  unhealthy_threshold = 3

  # HTTP でアプリケーションの正常性を確認します。
  http_health_check {
    # ヘルスチェックが接続するポート番号です。
    port = local.app_port
    # ヘルスチェックでリクエストするパスです。
    request_path = "/healthz"
  }

  # 任意: ヘルスチェックログの出力設定です。
  log_config {
    # false のため、ヘルスチェックログを追加出力しません。
    enable = false
  }
}

resource "google_compute_instance" "app" {
  # 作成する app VM の台数です。
  count = var.app_instance_count

  # app VM の名前です。複数台作成するため連番を付与します。
  name = format("%s-app-%02d", var.name_prefix, count.index + 1)
  # app VM に割り当てるマシンタイプです。
  machine_type = var.app_machine_type
  # app VM を作成するゾーンです。
  zone = var.zone
  # ファイアウォール適用などに利用するネットワークタグです。
  tags = ["${var.name_prefix}-app", "${var.name_prefix}-vm"]
  # app VM に付与するラベルです。
  labels = merge(local.labels, { component = "app" })
  # 任意: VM の用途を説明するテキストです。
  description = "${var.name_prefix} app instance"
  # 任意: false のため、VM は IP パケット転送を行いません。
  can_ip_forward = false
  # 任意: false のため、Terraform destroy で削除可能です。
  deletion_protection = false
  # 任意: 停止が必要な更新を Terraform が実行できるようにします。
  allow_stopping_for_update = true

  # VM のブートディスク設定です。
  boot_disk {
    # 任意: VM 削除時にブートディスクも削除します。
    auto_delete = true
    # 任意: ブートディスクを読み書き可能な状態でアタッチします。
    mode = "READ_WRITE"

    # ブートディスクの初期化設定です。
    initialize_params {
      # ブートディスクに利用する OS イメージです。
      image = data.google_compute_image.debian.self_link
    }
  }

  # VM のネットワークインターフェース設定です。
  network_interface {
    # VM を接続するサブネットです。
    subnetwork = google_compute_subnetwork.main.id
    # 任意: IPv4 のみのネットワークインターフェースとして作成します。
    stack_type = "IPV4_ONLY"
  }

  # VM 初回起動時に実行するスタートアップスクリプトです。
  metadata_startup_script = local.app_startup_script

  # VM が利用するサービスアカウント設定です。
  service_account {
    # VM に割り当てるサービスアカウントのメールアドレスです。
    email = google_service_account.vm.email
    # VM から Google Cloud API を利用できる OAuth スコープです。
    scopes = ["cloud-platform"]
  }

  # 任意: VM のホストメンテナンスや自動再起動に関する設定です。
  scheduling {
    # ホスト障害などの後に VM を自動再起動します。
    automatic_restart = true
    # ホストメンテナンス時に VM をライブマイグレーションします。
    on_host_maintenance = "MIGRATE"
    # 通常のオンデマンド VM として作成します。
    provisioning_model = "STANDARD"
    # プリエンプティブル VM としては作成しません。
    preemptible = false
  }

  # 任意: Shielded VM のセキュリティ機能を設定します。
  shielded_instance_config {
    # Secure Boot は有効化しません。
    enable_secure_boot = false
    # vTPM を有効化します。
    enable_vtpm = true
    # 整合性モニタリングを有効化します。
    enable_integrity_monitoring = true
  }
}

resource "google_compute_instance_group" "app" {
  # app VM をまとめる self-managed instance group の名前です。
  name = "${var.name_prefix}-app-ig"
  # instance group を作成するゾーンです。
  zone = var.zone
  # instance group に登録する app VM の self link 一覧です。
  instances = google_compute_instance.app[*].self_link
  # 任意: instance group の用途を説明するテキストです。
  description = "${var.name_prefix} app instance group"

  # ロードバランサーから参照する名前付きポートです。
  named_port {
    # バックエンドサービスが参照するポート名です。
    name = "http"
    # app VM が HTTP リクエストを受け付けるポート番号です。
    port = local.app_port
  }
}

resource "google_compute_backend_service" "app" {
  # HTTP ロードバランサーのバックエンドサービス名です。
  name = "${var.name_prefix}-app-backend"
  # 任意: バックエンドサービスの用途を説明するテキストです。
  description = "Backend service for ${var.name_prefix} app instances"
  # 外部 HTTP ロードバランサーとして利用します。
  load_balancing_scheme = "EXTERNAL"
  # バックエンドへ転送するプロトコルです。
  protocol = "HTTP"
  # instance group の named_port と対応するポート名です。
  port_name = "http"
  # バックエンドへのリクエストタイムアウト秒数です。
  timeout_sec = 30
  # app VM の正常性を確認するヘルスチェックです。
  health_checks = [google_compute_health_check.app.id]
  # 任意: Cloud CDN は利用しません。
  enable_cdn = false
  # 任意: セッションアフィニティは利用しません。
  session_affinity = "NONE"
  # 任意: バックエンドからの接続ドレイン待機時間です。0 秒のため待機しません。
  connection_draining_timeout_sec = 0

  # バックエンドとして app instance group を接続します。
  backend {
    # ロードバランサーが転送先として利用する instance group です。
    group = google_compute_instance_group.app.self_link
    # 任意: バックエンド全体の有効容量比率です。
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "app" {
  # URL マップの名前です。
  name = "${var.name_prefix}-url-map"
  # 任意: URL マップの用途を説明するテキストです。
  description = "URL map for ${var.name_prefix} app load balancer"
  # すべてのリクエストを転送するデフォルトのバックエンドサービスです。
  default_service = google_compute_backend_service.app.id
}

resource "google_compute_target_http_proxy" "app" {
  # HTTP プロキシの名前です。
  name = "${var.name_prefix}-http-proxy"
  # 任意: HTTP プロキシの用途を説明するテキストです。
  description = "HTTP proxy for ${var.name_prefix} app load balancer"
  # リクエストのルーティングに利用する URL マップです。
  url_map = google_compute_url_map.app.id
}

resource "google_compute_global_address" "lb" {
  # ロードバランサーに割り当てるグローバル静的 IP アドレスの名前です。
  name = "${var.name_prefix}-lb-ip"
  # 任意: 静的 IP アドレスの用途を説明するテキストです。
  description = "Global external IP address for ${var.name_prefix} HTTP load balancer"
  # 任意: 外部公開用の IP アドレスとして予約します。
  address_type = "EXTERNAL"
  # 任意: IPv4 アドレスを予約します。
  ip_version = "IPV4"
}

resource "google_compute_global_forwarding_rule" "http" {
  # HTTP リクエストを受け付けるグローバル転送ルール名です。
  name = "${var.name_prefix}-http-forwarding-rule"
  # 任意: 転送ルールの用途を説明するテキストです。
  description = "Forward HTTP traffic to ${var.name_prefix} app load balancer"
  # ロードバランサーに割り当てるグローバル静的 IP アドレスです。
  ip_address = google_compute_global_address.lb.address
  # 公開するポート範囲です。
  port_range = "80"
  # 外部ロードバランサーとして利用します。
  load_balancing_scheme = "EXTERNAL"
  # 任意: HTTP は TCP 上で動作するため TCP を指定します。
  ip_protocol = "TCP"
  # 任意: グローバル HTTP ロードバランサー向けに Premium Tier を利用します。
  network_tier = "PREMIUM"
  # リクエストを転送する HTTP プロキシです。
  target = google_compute_target_http_proxy.app.id
}

resource "google_compute_instance" "db" {
  # db VM の名前です。
  name = "${var.name_prefix}-db"
  # db VM に割り当てるマシンタイプです。
  machine_type = var.db_machine_type
  # db VM を作成するゾーンです。
  zone = var.zone
  # ファイアウォール適用などに利用するネットワークタグです。
  tags = ["${var.name_prefix}-db", "${var.name_prefix}-vm"]
  # db VM に付与するラベルです。
  labels = merge(local.labels, { component = "db" })
  # 任意: VM の用途を説明するテキストです。
  description = "${var.name_prefix} db instance"
  # 任意: false のため、VM は IP パケット転送を行いません。
  can_ip_forward = false
  # 任意: false のため、Terraform destroy で削除可能です。
  deletion_protection = false
  # 任意: 停止が必要な更新を Terraform が実行できるようにします。
  allow_stopping_for_update = true

  # VM のブートディスク設定です。
  boot_disk {
    # 任意: VM 削除時にブートディスクも削除します。
    auto_delete = true
    # 任意: ブートディスクを読み書き可能な状態でアタッチします。
    mode = "READ_WRITE"

    # ブートディスクの初期化設定です。
    initialize_params {
      # ブートディスクに利用する OS イメージです。
      image = data.google_compute_image.debian.self_link
    }
  }

  # VM のネットワークインターフェース設定です。
  network_interface {
    # VM を接続するサブネットです。
    subnetwork = google_compute_subnetwork.main.id
    # 任意: IPv4 のみのネットワークインターフェースとして作成します。
    stack_type = "IPV4_ONLY"
  }

  # VM が利用するサービスアカウント設定です。
  service_account {
    # VM に割り当てるサービスアカウントのメールアドレスです。
    email = google_service_account.vm.email
    # VM から Google Cloud API を利用できる OAuth スコープです。
    scopes = ["cloud-platform"]
  }

  # 任意: VM のホストメンテナンスや自動再起動に関する設定です。
  scheduling {
    # ホスト障害などの後に VM を自動再起動します。
    automatic_restart = true
    # ホストメンテナンス時に VM をライブマイグレーションします。
    on_host_maintenance = "MIGRATE"
    # 通常のオンデマンド VM として作成します。
    provisioning_model = "STANDARD"
    # プリエンプティブル VM としては作成しません。
    preemptible = false
  }

  # 任意: Shielded VM のセキュリティ機能を設定します。
  shielded_instance_config {
    # Secure Boot は有効化しません。
    enable_secure_boot = false
    # vTPM を有効化します。
    enable_vtpm = true
    # 整合性モニタリングを有効化します。
    enable_integrity_monitoring = true
  }
}

resource "google_compute_instance" "monitor" {
  # monitor VM の名前です。
  name = "${var.name_prefix}-monitor"
  # monitor VM に割り当てるマシンタイプです。
  machine_type = var.monitor_machine_type
  # monitor VM を作成するゾーンです。
  zone = var.zone
  # ファイアウォール適用などに利用するネットワークタグです。
  tags = ["${var.name_prefix}-monitor", "${var.name_prefix}-vm"]
  # monitor VM に付与するラベルです。
  labels = merge(local.labels, { component = "monitor" })
  # 任意: VM の用途を説明するテキストです。
  description = "${var.name_prefix} monitor instance"
  # 任意: false のため、VM は IP パケット転送を行いません。
  can_ip_forward = false
  # 任意: false のため、Terraform destroy で削除可能です。
  deletion_protection = false
  # 任意: 停止が必要な更新を Terraform が実行できるようにします。
  allow_stopping_for_update = true

  # VM のブートディスク設定です。
  boot_disk {
    # 任意: VM 削除時にブートディスクも削除します。
    auto_delete = true
    # 任意: ブートディスクを読み書き可能な状態でアタッチします。
    mode = "READ_WRITE"

    # ブートディスクの初期化設定です。
    initialize_params {
      # ブートディスクに利用する OS イメージです。
      image = data.google_compute_image.debian.self_link
    }
  }

  # VM のネットワークインターフェース設定です。
  network_interface {
    # VM を接続するサブネットです。
    subnetwork = google_compute_subnetwork.main.id
    # 任意: IPv4 のみのネットワークインターフェースとして作成します。
    stack_type = "IPV4_ONLY"
  }

  # VM が利用するサービスアカウント設定です。
  service_account {
    # VM に割り当てるサービスアカウントのメールアドレスです。
    email = google_service_account.vm.email
    # VM から Google Cloud API を利用できる OAuth スコープです。
    scopes = ["cloud-platform"]
  }

  # 任意: VM のホストメンテナンスや自動再起動に関する設定です。
  scheduling {
    # ホスト障害などの後に VM を自動再起動します。
    automatic_restart = true
    # ホストメンテナンス時に VM をライブマイグレーションします。
    on_host_maintenance = "MIGRATE"
    # 通常のオンデマンド VM として作成します。
    provisioning_model = "STANDARD"
    # プリエンプティブル VM としては作成しません。
    preemptible = false
  }

  # 任意: Shielded VM のセキュリティ機能を設定します。
  shielded_instance_config {
    # Secure Boot は有効化しません。
    enable_secure_boot = false
    # vTPM を有効化します。
    enable_vtpm = true
    # 整合性モニタリングを有効化します。
    enable_integrity_monitoring = true
  }
}

resource "google_storage_bucket" "function_source" {
  # Cloud Function のソースアーカイブを保存する GCS バケット名です。
  name = "${local.bucket_prefix}-${random_id.bucket_suffix.hex}"
  # バケットを作成するロケーションです。
  location = var.region
  # 任意: バケットを作成する対象の GCP プロジェクト ID です。
  project = var.project_id
  # IAM をバケット単位で統一し、オブジェクト ACL を利用しない設定です。
  uniform_bucket_level_access = true
  # バケットにオブジェクトが残っていても Terraform destroy で削除できるかを制御します。
  force_destroy = var.force_destroy_buckets
  # バケットに付与するラベルです。
  labels = merge(local.labels, { component = "function-source" })
  # 任意: 標準ストレージクラスを利用します。
  storage_class = "STANDARD"
  # 任意: バケットの公開を防止します。
  public_access_prevention = "enforced"

  # Cloud Storage API が有効化された後にバケットを作成します。
  depends_on = [
    google_project_service.required["storage.googleapis.com"],
  ]
}

data "archive_file" "function_source" {
  # 作成するアーカイブ形式です。
  type = "zip"
  # ZIP 化する Cloud Function ソースディレクトリです。
  source_dir = "${path.module}/function"
  # 生成する ZIP ファイルの出力先です。
  output_path = "${path.module}/build/function-source.zip"
  # 任意: アーカイブから除外するファイルパターンです。空のため除外しません。
  excludes = []
}

resource "google_storage_bucket_object" "function_source" {
  # GCS にアップロードするオブジェクト名です。内容が変わると MD5 も変わります。
  name = "function-source-${data.archive_file.function_source.output_md5}.zip"
  # オブジェクトを保存する GCS バケット名です。
  bucket = google_storage_bucket.function_source.name
  # アップロード元となるローカル ZIP ファイルです。
  source = data.archive_file.function_source.output_path
  # アップロードするオブジェクトの Content-Type です。
  content_type = "application/zip"
  # 任意: オブジェクトに付与するカスタムメタデータです。空のため追加しません。
  metadata = {}
}

resource "google_cloudfunctions2_function" "http" {
  # Cloud Functions Gen2 関数の名前です。
  name = "${var.name_prefix}-function"
  # 関数をデプロイするリージョンです。
  location = var.region
  # 任意: 関数を作成する対象の GCP プロジェクト ID です。
  project = var.project_id
  # 関数の用途を説明するテキストです。
  description = "HTTP Cloud Function for ${var.name_prefix}"
  # 関数に付与するラベルです。
  labels = merge(local.labels, { component = "function" })

  # Cloud Function のビルド設定です。
  build_config {
    # 関数で利用するランタイムです。
    runtime = var.function_runtime
    # HTTP リクエストを処理するエントリーポイント関数名です。
    entry_point = "hello_http"
    # 任意: ビルド時に渡す環境変数です。空のため追加しません。
    environment_variables = {}

    # 関数ソースコードの取得元です。
    source {
      # Cloud Storage 上のソースアーカイブを指定します。
      storage_source {
        # ソースアーカイブを保存した GCS バケット名です。
        bucket = google_storage_bucket.function_source.name
        # ソースアーカイブの GCS オブジェクト名です。
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  # Cloud Function の実行時設定です。
  service_config {
    # 関数の最大インスタンス数です。
    max_instance_count = var.function_max_instance_count
    # 任意: 関数の最小インスタンス数です。0 のため常時起動インスタンスは持ちません。
    min_instance_count = 0
    # 関数に割り当てるメモリ量です。
    available_memory = var.function_memory
    # 関数のタイムアウト秒数です。
    timeout_seconds = var.function_timeout_seconds
    # すべての ingress からのアクセスを許可します。
    ingress_settings = "ALLOW_ALL"
    # 最新リビジョンへすべてのトラフィックを流します。
    all_traffic_on_latest_revision = true
    # 関数実行時に利用するサービスアカウントです。
    service_account_email = google_service_account.function.email

    # 関数実行時に渡す環境変数です。
    environment_variables = {
      # 関数内から参照できる GCP プロジェクト ID です。
      PROJECT_ID = var.project_id
    }
  }

  # Cloud Function のビルドと実行に必要な API が有効化された後に作成します。
  depends_on = [
    google_project_service.required["artifactregistry.googleapis.com"],
    google_project_service.required["cloudbuild.googleapis.com"],
    google_project_service.required["cloudfunctions.googleapis.com"],
    google_project_service.required["run.googleapis.com"],
  ]
}

resource "google_cloud_run_service_iam_member" "function_public_invoker" {
  # 未認証アクセスを許可する設定の場合だけ IAM バインディングを作成します。
  count = var.allow_unauthenticated_function ? 1 : 0

  # IAM を設定する対象の GCP プロジェクト ID です。
  project = var.project_id
  # IAM を設定する Cloud Run サービスのロケーションです。
  location = google_cloudfunctions2_function.http.location
  # Cloud Functions Gen2 の実体である Cloud Run サービス名です。
  service = google_cloudfunctions2_function.http.name
  # 関数を呼び出す権限を表す IAM ロールです。
  role = "roles/run.invoker"
  # すべてのユーザーに呼び出しを許可するメンバー指定です。
  member = "allUsers"
}
