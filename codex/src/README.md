# Grafana Alert Analyzer

Grafana Alerting の webhook を受け、Gemini Enterprise に接続された社内情報を使ってアラートを分析する Go サービスです。分析結果は Markdown ファイルとして Google Drive に保存し、そのリンクを Slack Incoming Webhook に通知します。

分析レポートには次の4項目を必ず生成するようGemini Enterpriseへ指示します。

- 現状把握
- 原因調査
- 解決策提案
- 確認方法

Webhook は処理をインメモリキューへ登録して `202 Accepted` を返します。後続処理は非同期です。コンテナ終了時にはキュー済み処理の完了を最大30秒待ちます。

## 前提条件

- Gemini Enterprise のアプリと Assistant が作成済みであること
- Google Drive API と Discovery Engine API が有効であること
- 実行サービスアカウントに対象Assistantを利用できる権限（例: Discovery Engine User）があること
- Driveの保存先フォルダが実行サービスアカウントへ編集者として共有されていること
- Slack AppでIncoming Webhook URLが発行済みであること

APIを有効化する例です。

```bash
gcloud services enable \
  discoveryengine.googleapis.com \
  drive.googleapis.com \
  artifactregistry.googleapis.com \
  --project="YOUR_PROJECT_ID"
```

## 設定

| 環境変数 | 必須 | 既定値 | 説明 |
|---|---:|---:|---|
| `GEMINI_ASSISTANT` | yes | - | `projects/PROJECT/locations/global/collections/default_collection/engines/APP/assistants/default_assistant` 形式の完全リソース名 |
| `GOOGLE_DRIVE_FOLDER_ID` | yes | - | Markdownを保存するDriveフォルダID。共有ドライブにも対応 |
| `SLACK_WEBHOOK_URL` | yes | - | Slack Incoming Webhook URL（秘密情報として管理） |
| `WEBHOOK_TOKEN` | yes | - | Grafanaから送るBearer token |
| `PORT` | no | `8080` | HTTP listen port |
| `MAX_BODY_BYTES` | no | `1048576` | webhook request body上限 |
| `QUEUE_SIZE` | no | `100` | インメモリキュー長 |
| `WORKERS` | no | `2` | 並列処理数 |
| `UPSTREAM_TIMEOUT_SECONDS` | no | `120` | Google/Slack API timeout |

Google APIの認証にはApplication Default Credentials (ADC)を使います。Cloud RunやGKEではWorkload Identityまたは実行サービスアカウントを使用してください。ローカル確認でサービスアカウント鍵を使う場合に限り、鍵をコンテナへread-only mountし、`GOOGLE_APPLICATION_CREDENTIALS`を指定します。鍵やSlack URLをイメージへ含めないでください。

## Docker imageのビルド

```bash
docker build -t grafana-alert-analyzer:local .
```

ローカル実行例です。

```bash
docker run --rm -p 8080:8080 \
  -v "$(pwd)/credentials.json:/var/run/secrets/google/credentials.json:ro" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/var/run/secrets/google/credentials.json \
  -e GEMINI_ASSISTANT="projects/YOUR_PROJECT_ID/locations/global/collections/default_collection/engines/YOUR_APP_ID/assistants/default_assistant" \
  -e GOOGLE_DRIVE_FOLDER_ID="YOUR_FOLDER_ID" \
  -e SLACK_WEBHOOK_URL="YOUR_SLACK_INCOMING_WEBHOOK_URL" \
  -e WEBHOOK_TOKEN="YOUR_RANDOM_SECRET" \
  grafana-alert-analyzer:local
```

ヘルスチェック:

```bash
curl --fail http://localhost:8080/healthz
```

## Artifact Registryへのpush

初回のみDockerリポジトリを作り、Docker認証を設定します。以下は東京リージョンの例です。

```bash
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="asia-northeast1"
export REPOSITORY="containers"
export IMAGE="grafana-alert-analyzer"
export TAG="v1.0.0"

gcloud artifacts repositories create "$REPOSITORY" \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT_ID"

gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

実行ユーザーには対象リポジトリの Artifact Registry Writer (`roles/artifactregistry.writer`) が必要です。イメージをArtifact Registry名でビルドしてpushします。

```bash
docker build \
  -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}" \
  .

docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}"
```

Apple Siliconなどから `linux/amd64` と `linux/arm64` の両方を直接pushする場合:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE}:${TAG}" \
  --push .
```

## Grafanaの設定

Grafana AlertingでWebhook contact pointを追加します。

- URL: `https://YOUR_SERVICE/webhook/grafana`
- HTTP Method: `POST`
- Authorization Header Scheme: `Bearer`
- Authorization credentials: `WEBHOOK_TOKEN`と同じ値

疎通確認用の最小リクエスト:

```bash
curl --fail-with-body -X POST http://localhost:8080/webhook/grafana \
  -H "Authorization: Bearer YOUR_RANDOM_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "receiver": "operations",
    "status": "firing",
    "title": "High error rate",
    "groupKey": "service=api",
    "alerts": [{
      "status": "firing",
      "labels": {"service": "api", "severity": "critical"},
      "annotations": {"summary": "5xx error rate exceeded 5%"}
    }]
  }'
```

正常にキューへ登録されると `202` と `{"status":"accepted"}` が返ります。`503` はキュー満杯、`401` はtoken不一致、`400` は不正payloadです。

## 開発時の確認

```bash
go test ./...
go vet ./...
```
