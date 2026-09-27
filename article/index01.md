# 記事タイトル

## はじめに
こんにちは、新井です。

## アジェンダ

1. **全体構成** — アプリケーション、データベース、監視の各サーバーの役割
2. **アプリケーションサーバー** — NGINXとPHP-FPM、および各Exporter
3. **データベースサーバー** — MySQLとMySQL Exporter
4. **監視サーバー** — VictoriaMetrics、VictoriaMetrics MCP Server、Grafana
5. **メトリクスの収集と可視化** — 各Exporterから監視基盤へつなぐ構成
6. **まとめ** — 構成の要点を振り返る

## 構成

![](blog%20_%20mcp%20server.png)

各種サーバ
- Application Server
  - NGINX
  - PHP-FPM
  - NGINX Exporter
  - PHP-FPM Exporter
- Database Server
  - MySQL
  - MySQL Exporter
- Monitor Server
  - VictoriaMetrics
  - VictoriaMetrics MCP Server
  - Grafana

## まとめ
