# 記事タイトル

## はじめに
こんにちは、新井です。
インフラを運用していてこんなことを思ったことはないでしょうか？
・アラート原因を調査するために複数のメトリクスを横断的に確認するのが面倒


そこで今回は、VictoriaMtrics/VictoriaLogs/VictoriaTracesとMCP Serverを組み合わせ、Grafana Alertを起点にGemini Enterpriseに調査をさせる仕組みを試してみます。

構成としては、Grafanaでアラートを検知するとCloudRun経由でGemini Enterpriseを呼び出し、Gemini Enterpriseから各MCP Serverを利用してVictoriaMetrics, VictoriaLogs, VictoriaTracesの情報を取得できるようにします。

## 構成

![](configuration_diagram.png)

各種サーバ
- Application Server
  - NGINX
  - PHP-FPM
  - NGINX Exporter
  - PHP-FPM Exporter
  - OpenTelemetry Collector
- Database Server
  - MySQL
  - MySQL Exporter
  - OpenTelemetry Collector
- Monitor Server
  - VictoriaMetrics
  - VictoriaLogs
  - VictoriaTrace
  - VictoriaMetrics MCP Server
  - VictoriaLogs MCP Server
  - VictoriaTrace MCP Server
  - Grafana
- Gemini Hook (Cloud Run)
  - Golang

基本的にはApplicationとDatabaseからメトリクス、ログ、トレースをVictoriaMetrics/Logs/Tracesへ集約し、grafanaから描画します。
そこへMCP Serverを追加しgemini enterpriseからアクセスできるようにします。
またgrafana alertが発報された際に、

## 処理フロー

```plantuml
@startuml
title Grafana Alert -> Gemini Enterprise 自動調査フロー

autonumber

participant "Grafana" as Grafana
participant "Cloud Run\nWebhook" as CloudRun
participant "Gemini Enterprise" as Gemini

participant "VictoriaMetrics\nMCP Server" as VMMCP
participant "VictoriaLogs\nMCP Server" as VLMCP
participant "VictoriaTrace\nMCP Server" as VTMCP

database "VictoriaMetrics" as VM
database "VictoriaLogs" as VL
database "VictoriaTrace" as VT


== Grafana Alert 発火 ==

Grafana -> CloudRun : Alert Webhook\nAlert名 / 時刻 / Labels / Annotations
activate CloudRun

CloudRun -> CloudRun : Alert情報を検証・整形

CloudRun -> Gemini : 障害調査を依頼\n・現状把握\n・原因調査\n・対応方法
activate Gemini


== 1. 現状把握 ==

par Metrics調査
    Gemini -> VMMCP : Alert前後のMetricsを調査
    VMMCP -> VM : Metrics Query
    VM --> VMMCP : Metrics
    VMMCP --> Gemini : Metrics調査結果

else Logs調査
    Gemini -> VLMCP : Alert前後のLogsを調査
    VLMCP -> VL : Logs Query
    VL --> VLMCP : Logs
    VLMCP --> Gemini : Logs調査結果

else Traces調査
    Gemini -> VTMCP : Alert前後のTracesを調査
    VTMCP -> VT : Traces Query
    VT --> VTMCP : Traces
    VTMCP --> Gemini : Traces調査結果
end


Gemini -> Gemini : 現状把握\n・影響範囲\n・エラー率\n・Latency\n・CPU / Memory\n・異常Log / Trace

== 2. アラート原因調査 ==

Gemini -> Gemini : Metrics / Logs / Tracesを\n相関分析

loop 原因を特定できるまで追加調査

    alt Metricsの追加調査が必要
        Gemini -> VMMCP : 詳細Metrics調査
        VMMCP -> VM : Query
        VM --> VMMCP : Result
        VMMCP --> Gemini : Result

    else Logsの追加調査が必要
        Gemini -> VLMCP : 関連Logs調査
        VLMCP -> VL : Query
        VL --> VLMCP : Result
        VLMCP --> Gemini : Result

    else Tracesの追加調査が必要
        Gemini -> VTMCP : 関連Traces調査
        VTMCP -> VT : Query
        VT --> VTMCP : Result
        VTMCP --> Gemini : Result
    end

    Gemini -> Gemini : 原因仮説を検証

end


Gemini -> Gemini : Root Causeを整理

Gemini -> Gemini : 対応方法を生成\n・緊急対応\n・恒久対応\n・追加確認事項


note right of Gemini

【現状把握】
・HTTP 5xx 増加
・Latency 上昇
・PHP-FPM Queue 増加

【推定原因】
PHP-FPM max_children 到達

【根拠】
Metrics:
active_process = max_children

Logs:
server reached max_children

Traces:
PHP処理待ち時間が増加

【対応方法】

緊急対応:
・PHP-FPM worker増加
・CPU / Memory確認

恒久対応:
・max_children最適化
・Slow Request調査
・Application性能改善

end note


Gemini --> CloudRun : 調査結果\n・現状把握\n・原因\n・根拠\n・対応方法

deactivate Gemini

CloudRun -> CloudRun : 結果を整形

note right of CloudRun
後段として

・Slack
・Google Chat
・PagerDuty
・Incident管理

などへ通知可能
end note

deactivate CloudRun
@enduml
```


## 試したユースケース

## まとめ