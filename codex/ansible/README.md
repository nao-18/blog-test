# Middleware Ansible

3台のVMへミドルウェアを直接インストールするAnsible Playbookです。Dockerやコンテナは使用せず、Debian/UbuntuではAPT、Rocky/RHELではDNFを使用し、各プロジェクトの公式リリースバイナリと合わせてsystemdサービスとして管理します。Docker Engine、Compose、containerdのインストール・停止・削除処理はPlaybookに含めていません。

## 構成

| VMグループ | 導入するサービス |
|---|---|
| `app` | Nginx、PHP-FPM、Nginx exporter、PHP-FPM exporter、node exporter、Grafana Alloy、OpenTelemetry Collector |
| `db` | MySQL互換サーバー、mysqld exporter、node exporter、Grafana Alloy、OpenTelemetry Collector |
| `monitor` | VictoriaMetrics、VictoriaLogs、VictoriaTraces、各MCP Server、Grafana、node exporter、Grafana Alloy、OpenTelemetry Collector |

各VMのAlloyは、exporterのメトリクスをVictoriaMetricsへ、systemd journalのログをVictoriaLogsへ送信します。OpenTelemetry CollectorはOTLPで受信したmetrics、logs、tracesを、それぞれ対応するVictoria製品へ送信します。

## 前提条件

### Ansibleコントローラー

- Ansible Core 2.15以降
- 対象VMへSSH接続できること
- 対象VMのホスト鍵が `known_hosts` に登録されていること
- `sudo` またはroot権限を利用できるSSHユーザー

バージョンを確認します。

```bash
ansible --version
ansible-playbook --version
```

### 対象VM

- Debian、Ubuntu、Rocky Linux、またはRHEL系OS
- `x86_64` または `aarch64`
- systemdを使用していること
- インターネット上のOSパッケージリポジトリとGitHub ReleasesへHTTPS接続できること
- app、db、monitorの各VMが相互にプライベートネットワークで通信できること

推奨する最小構成は次のとおりです。実際に必要なCPU、メモリ、ディスク容量は保存期間と取り込み量に応じて調整してください。

| VM | vCPU | メモリ | ディスク |
|---|---:|---:|---:|
| app | 2 | 2 GB | 20 GB |
| db | 2 | 4 GB | 40 GB |
| monitor | 4 | 8 GB | 100 GB以上 |

## VMのIPアドレスまたはhostnameを指定する

接続先は [inventories/production/hosts.yml](inventories/production/hosts.yml) に記述します。`app`、`db`、`monitor` の各グループに最低1台ずつ指定してください。

### IPアドレスを指定する場合

`ansible_host` にVMのIPアドレスを指定します。インベントリ上の `app01`、`db01`、`monitor01` はAnsible内部で使う任意の識別名です。

```yaml
---
all:
  children:
    app:
      hosts:
        app01:
          ansible_host: 192.168.10.11
    db:
      hosts:
        db01:
          ansible_host: 192.168.10.12
    monitor:
      hosts:
        monitor01:
          ansible_host: 192.168.10.13
```

### DNS名またはhostnameを指定する場合

DNS、`/etc/hosts`、またはSSH設定で名前解決できるhostnameを `ansible_host` に指定します。

```yaml
---
all:
  children:
    app:
      hosts:
        app01:
          ansible_host: app.internal.example.com
    db:
      hosts:
        db01:
          ansible_host: db.internal.example.com
    monitor:
      hosts:
        monitor01:
          ansible_host: monitor.internal.example.com
```

インベントリ名そのものが名前解決できる場合は、`ansible_host` を省略できます。

```yaml
---
all:
  children:
    app:
      hosts:
        app.internal.example.com:
    db:
      hosts:
        db.internal.example.com:
    monitor:
      hosts:
        monitor.internal.example.com:
```

app/db VMからmonitor VMへの送信先にもmonitorの `ansible_host` が初期値として使われます。そのため、monitorに指定するhostnameはAnsibleコントローラーだけでなくapp/db VMからも名前解決できるものにしてください。コントローラー専用のSSH aliasや踏み台用アドレスを使う場合は、後述する `monitor_address` にVM間通信用のIPまたはhostnameを別途指定します。

### SSHユーザー、ポート、秘密鍵も指定する場合

全VMで設定が同じ場合は `all.vars` に記述します。次の例ではSSHユーザーを `ansible`、SSHポートを `22`、秘密鍵をコントローラー上のファイルに設定しています。

```yaml
---
all:
  vars:
    ansible_user: ansible
    ansible_port: 22
    ansible_ssh_private_key_file: /home/operator/.ssh/middleware_ed25519
  children:
    app:
      hosts:
        app01:
          ansible_host: 192.168.10.11
    db:
      hosts:
        db01:
          ansible_host: 192.168.10.12
    monitor:
      hosts:
        monitor01:
          ansible_host: 192.168.10.13
```

VMごとにSSH設定が異なる場合は、対象ホストの下へ個別に記述します。

```yaml
app01:
  ansible_host: 192.168.10.11
  ansible_user: ubuntu
  ansible_port: 2222
  ansible_ssh_private_key_file: /home/operator/.ssh/app_key
```

秘密鍵にパスフレーズが設定されている場合は、事前に `ssh-agent` へ登録する方法を推奨します。

```bash
eval "$(ssh-agent -s)"
ssh-add /home/operator/.ssh/middleware_ed25519
```

### SSH設定ファイルのHost名を使用する場合

`~/.ssh/config` に接続情報がある場合、そのHost名を `ansible_host` に指定できます。

```sshconfig
Host middleware-app
  HostName 192.168.10.11
  User ubuntu
  IdentityFile ~/.ssh/middleware_ed25519
```

```yaml
app:
  hosts:
    app01:
      ansible_host: middleware-app
```

## 秘密情報を設定する

パスワードは平文の変数ファイルへ直接保存せず、Ansible Vaultで暗号化します。

まずサンプルをコピーします。

```bash
cp inventories/production/group_vars/vault.yml.example \
  inventories/production/group_vars/vault.yml
```

`inventories/production/group_vars/vault.yml` を編集し、十分に長いランダム値を設定します。

```yaml
---
mysql_exporter_password: replace-with-a-long-random-value
grafana_admin_password: replace-with-another-long-random-value
```

ファイルを暗号化します。

```bash
ansible-vault encrypt inventories/production/group_vars/vault.yml
```

内容を確認または変更する場合は次を使用します。

```bash
ansible-vault view inventories/production/group_vars/vault.yml
ansible-vault edit inventories/production/group_vars/vault.yml
```

毎回Vaultパスワードを入力したくない場合は、権限を制限したパスワードファイルを用意し、`--vault-password-file` を使用できます。パスワードファイルをGitへ追加しないでください。

## 接続を確認する

インベントリが期待どおりに解釈されることを確認します。

```bash
ansible-inventory --graph
ansible-inventory --host app01
```

全VMへのSSH接続とsudo実行を確認します。

```bash
ansible all -m ansible.builtin.ping
ansible all -b -m ansible.builtin.command -a 'id'
```

sudoパスワードが必要なユーザーでは `--ask-become-pass` を付けます。

```bash
ansible all -b -m ansible.builtin.command -a 'id' --ask-become-pass
```

接続に失敗する場合は、まずAnsibleを使わずに同じ接続条件でSSHできるか確認してください。

```bash
ssh -i /home/operator/.ssh/middleware_ed25519 ansible@192.168.10.11
```

## 変数を確認する

共通設定は [inventories/production/group_vars/all.yml](inventories/production/group_vars/all.yml) にあります。

主な変数は次のとおりです。

| 変数 | 初期値 | 用途 |
|---|---|---|
| `service_bind_address` | `0.0.0.0` | アプリ、MySQL、Victoria製品、OTLPの待受アドレス |
| `admin_bind_address` | `127.0.0.1` | exporter、MCP Server、Grafanaなど管理系エンドポイントの待受アドレス |
| `monitor_address` | monitorグループ先頭VMの `ansible_host` | app/db VMから監視VMへ送信するときのアドレス |
| `*_version` | ファイル内の固定値 | 公式バイナリのバージョン |

`monitor_address` は通常、自動的にmonitor VMのIPまたはhostnameになります。NATや踏み台構成などで `ansible_host` とVM間通信用アドレスが異なる場合は、明示的に上書きします。

```yaml
monitor_address: 10.0.20.13
```

本番環境では `service_bind_address: 0.0.0.0` のままインターネットへ公開しないでください。VM間通信に使うプライベートIPを指定するか、セキュリティグループまたはホストファイアウォールで接続元を制限してください。

## 構文を確認する

VMへ変更を加える前に構文を確認します。

```bash
ansible-playbook --syntax-check site.yml
ansible-playbook --syntax-check verify.yml
```

変更内容の予測にはチェックモードを使用できます。ただし、パッケージ導入後に生成される情報やサービス状態を利用するタスクがあるため、新規VMに対するチェックモードだけでは最後まで完走しない場合があります。

```bash
ansible-playbook site.yml --check --diff --ask-vault-pass
```

## ミドルウェアを構築する

全VMへ適用します。

```bash
ansible-playbook site.yml --ask-vault-pass
```

sudoパスワードも必要な場合は両方を指定します。

```bash
ansible-playbook site.yml --ask-vault-pass --ask-become-pass
```

Vaultパスワードファイルを使用する場合は次のように実行します。

```bash
ansible-playbook site.yml \
  --vault-password-file /secure/path/vault-password
```

### 特定のVMまたはグループだけへ適用する

`--limit` で対象を限定できます。

```bash
# appグループのみ
ansible-playbook site.yml --limit app --ask-vault-pass

# monitor01のみ
ansible-playbook site.yml --limit monitor01 --ask-vault-pass

# appとdbのみ
ansible-playbook site.yml --limit 'app:db' --ask-vault-pass
```

ただし、app/dbのAlloyとOpenTelemetry Collectorはmonitor VMへ送信するため、初回構築ではmonitorを含めて全体を適用することを推奨します。

## 稼働確認を実行する

構築後、HTTPエンドポイントとexporterを確認します。

```bash
ansible-playbook verify.yml --ask-vault-pass
```

グループを限定した確認もできます。

```bash
ansible-playbook verify.yml --limit app --ask-vault-pass
ansible-playbook verify.yml --limit monitor --ask-vault-pass
```

## 主なポート

| VM | ポート | 用途 | 初期待受設定 |
|---|---:|---|---|
| app | 80 | Nginxアプリケーション | `service_bind_address` |
| app | 9113 | Nginx exporter | `admin_bind_address` |
| app | 9253 | PHP-FPM exporter | `admin_bind_address` |
| db | 3306 | MySQL | `service_bind_address` |
| db | 9104 | mysqld exporter | `admin_bind_address` |
| 全VM | 9100 | node exporter | `admin_bind_address` |
| 全VM | 4317 | OTLP/gRPC | `service_bind_address` |
| 全VM | 4318 | OTLP/HTTP | `service_bind_address` |
| 全VM | 8888 | OpenTelemetry Collectorメトリクス | `admin_bind_address` |
| monitor | 8428 | VictoriaMetrics | `service_bind_address` |
| monitor | 9428 | VictoriaLogs | `service_bind_address` |
| monitor | 10428 | VictoriaTraces | `service_bind_address` |
| monitor | 8081 | VictoriaMetrics MCP Server | `admin_bind_address` |
| monitor | 8082 | VictoriaLogs MCP Server | `admin_bind_address` |
| monitor | 8083 | VictoriaTraces MCP Server | `admin_bind_address` |
| monitor | 3000 | Grafana | `admin_bind_address` |

`admin_bind_address` の初期値は `127.0.0.1` です。管理画面へ手元のPCから接続する場合はSSHポートフォワードを使用できます。

```bash
ssh -L 3000:127.0.0.1:3000 ansible@monitor.internal.example.com
```

トンネル確立後、ブラウザで `http://127.0.0.1:3000/` を開きます。同様にMCP Serverを転送する例は次のとおりです。

```bash
ssh \
  -L 8081:127.0.0.1:8081 \
  -L 8082:127.0.0.1:8082 \
  -L 8083:127.0.0.1:8083 \
  ansible@monitor.internal.example.com
```

## systemdサービスを確認する

app VMでは次を確認します。

```bash
systemctl status nginx php*-fpm nginx-exporter php-fpm-exporter \
  node-exporter alloy otelcol-contrib
```

db VMでは次を確認します。

```bash
systemctl status mysql mysql-exporter node-exporter alloy otelcol-contrib
```

monitor VMでは次を確認します。

```bash
systemctl status \
  victoriametrics victorialogs victoriatraces \
  mcp-victoriametrics mcp-victorialogs mcp-victoriatraces \
  grafana-server node-exporter alloy otelcol-contrib
```

サービスログは `journalctl` で確認します。

```bash
journalctl -u victoriametrics -n 100 --no-pager
journalctl -u alloy -u otelcol-contrib -f
```

## データと設定の保存先

| 対象 | 保存先 |
|---|---|
| VictoriaMetrics | `/var/lib/victoria/metrics` |
| VictoriaLogs | `/var/lib/victoria/logs` |
| VictoriaTraces | `/var/lib/victoria/traces` |
| Grafana | `/var/lib/grafana` |
| MySQL | OSパッケージ標準のデータディレクトリ |
| Alloy設定 | `/etc/alloy/config.alloy` |
| OpenTelemetry Collector設定 | `/etc/otelcol-contrib/config.yaml` |
| 公式バイナリ | `/usr/local/bin` |
| systemd unit | `/etc/systemd/system` |

このPlaybookは永続データを削除しません。バックアップ、リストア、保存容量の監視は別途設計してください。

## 既存Docker環境から移行する場合

Dockerの停止・削除・データ移行は、このPlaybookとは別に実施してください。既存データが必要な場合は、適用前にバックアップを取得し、製品ごとの正式なバックアップ／リストア手順で移行します。

移行完了後、Docker Engine、Compose、関連リポジトリ、不要な `/var/lib/docker` を管理者が確認して削除してください。データ削除は不可逆のため、このPlaybookには含めていません。

## トラブルシューティング

### `UNREACHABLE` になる

- `ansible_host` のIPまたはhostnameが正しいか確認する
- DNSまたは `/etc/hosts` で名前解決できるか確認する
- `ansible_user`、`ansible_port`、秘密鍵を確認する
- VMのSSHポートとセキュリティグループを確認する
- `ssh` コマンドで直接接続できるか確認する

詳細ログを出す場合は `-vvv` を付けます。

```bash
ansible app01 -m ansible.builtin.ping -vvv
```

### sudoで失敗する

SSHユーザーがsudoを利用できるか確認し、必要なら `--ask-become-pass` を付けます。

```bash
ansible all -b -m ansible.builtin.command -a 'id' --ask-become-pass
```

### app/dbからmonitorへ送信できない

- `monitor_address` がVM間で到達可能なIPまたはhostnameか確認する
- 8428、9428、10428番ポートへの通信を確認する
- monitor VM上でVictoria製品が起動しているか確認する
- AlloyとOpenTelemetry Collectorのjournalを確認する

```bash
curl http://monitor.internal.example.com:8428/health
curl http://monitor.internal.example.com:9428/health
curl http://monitor.internal.example.com:10428/health
```

### サービスが起動しない

systemdの状態と直近のログを確認します。

```bash
systemctl --failed
systemctl status SERVICE_NAME
journalctl -u SERVICE_NAME -n 200 --no-pager
```

設定変更後は対象サービスを再起動します。通常はPlaybookを再実行すれば、変更された設定に対応するサービスが再起動されます。

### Rocky/RHELでOpenTelemetry CollectorのRPM署名エラーになる

次のエラーは、Rocky/RHELの `dnf` がRPMのGPG署名を検証したものの、対象のOpenTelemetry Collector Contrib RPM自体にRPM署名がない場合に発生します。

```text
Failed to validate GPG signature ... Package otelcol-contrib_...rpm is not signed
```

これはSSH、OS判定、またはRocky Linux 10の不具合ではありません。`dnf` の既定の署名検証と、署名されていないRPMの組み合わせが原因です。

このPlaybookでは、Red Hat系VMに限りRPMを `dnf` でインストールせず、OpenTelemetry公式リリースの同じバージョンのtarballを展開して `/usr/local/bin/otelcol-contrib` とsystemd unitを配置します。したがって、`disable_gpg_check: true` で署名検証を無効化する必要はありません。バージョンは `inventories/production/group_vars/all.yml` の `otel_collector_version` で固定し、更新時は公式リリースの配布物と変更履歴を確認してください。

修正後は次を再実行します。

```bash
ansible-playbook site.yml --limit monitor --ask-vault-pass
ansible-playbook site.yml --ask-vault-pass
systemctl status otelcol-contrib
journalctl -u otelcol-contrib -n 100 --no-pager
```

RPMを手動で導入する運用を選ぶ場合は、`dnf --nogpgcheck` や `disable_gpg_check: true` を常用せず、公式リリースのチェックサムを別途検証してから限定的に実行してください。署名検証を無効化したままインターネットから取得したRPMを導入する方法は推奨しません。

### Rocky Linux 10で`mysql-server`が見つからない

Rocky Linux 10では、AppStreamのMySQL 8.4サーバーパッケージ名が`mysql8.4-server`です。`No package mysql-server available.`と表示される場合は、古いパッケージ名を使用している可能性があります。このPlaybookではRocky/RHEL系に`mysql8.4-server`、Debian/Ubuntu系に`default-mysql-server`を使用します。

対象VMのリポジトリとパッケージを確認するには、次を実行します。

```bash
sudo dnf repolist
sudo dnf search mysql8.4-server
sudo dnf install mysql8.4-server
```

### Grafanaプラグイン導入時に`Could not find config defaults`になる

`grafana-cli`を作業ディレクトリから実行すると、Grafanaのhomepathを特定できず失敗することがあります。Playbookでは`grafana cli`に設定ファイル、homepath、プラグインディレクトリを明示しています。手動で確認する場合は次を実行します。

```bash
sudo grafana cli \
  --config /etc/grafana/grafana.ini \
  --homepath /usr/share/grafana \
  --pluginsDir /var/lib/grafana/plugins \
  plugins install victoriametrics-logs-datasource
```

## セキュリティ上の注意

- `inventories/production/group_vars/vault.yml` は必ずVault暗号化する
- VaultパスワードやSSH秘密鍵をリポジトリへ保存しない
- `service_bind_address` で公開されるポートをインターネットへ直接公開しない
- `admin_bind_address` は原則 `127.0.0.1` のまま使用する
- GrafanaとMCP Serverを外部公開する場合はTLS、認証、アクセス制御を追加する
- 本番環境ではバイナリバージョンを固定し、更新前に検証環境でテストする
- VMとミドルウェアのセキュリティ更新を定期的に適用する
