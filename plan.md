# sakurasake — 仕様書（現行実装）

**キャッチコピー:** 「進捗を、会場の景色に変える」

スマホ等から送った進捗が、メインスクリーンの Three.js シーン（桜の量・通知）にリアルタイム反映される。**リアルタイム経路は WebSocket のみ**（旧 SSE は廃止）。

---

## 技術スタック（実装どおり）

| 層 | 内容 |
|----|------|
| サーバ | Ruby 3.3+ / **Sinatra 4** / **Puma**（`rackup` 経由） |
| WebSocket | **faye-websocket**（`Faye::WebSocket.load_adapter("puma")` を [`server/config.ru`](server/config.ru) で読込） |
| フロント | 単体 [`index.html`](index.html)（Three.js モジュール CDN、スクリーンは `/screen` で配信） |
| コンテナ | [`Dockerfile`](Dockerfile) → `bundle exec rackup` / `PORT`（本番は `RACK_ENV=production`） |

**注意:** `ruby server/app.rb` だけの起動は想定外。WebSocket は Rack hijack が必要なため **`bundle exec rackup ... server/config.ru`** を使う。開発時も **Rack::Lint** が WebSocket のハイジャック応答と相性が悪い場合があるため、本番相当では `RACK_ENV=production` で起動するか、Lint を無効にした構成にする。

---

## リポジトリ構成（要点）

```
sakurasake/
├── index.html           # スクリーン UI（WebGL + WebSocket クライアント）
├── public/              # 静的ファイル
├── server/
│   ├── app.rb           # ルート・STATE・WS ブロードキャスト
│   ├── config.ru        # Puma アダプタ + Sinatra
│   └── Gemfile
├── Dockerfile
├── fly.toml             # Fly.io（任意）
└── plan.md              # 本書
```

---

## 共有状態（メモリ内）

[`server/app.rb`](server/app.rb) の `STATE`（プロセス内・単一マシン前提）:

| キー | 型 | 説明 |
|------|-----|------|
| `who` | string / nil | 表示名 |
| `message` | string / nil | メッセージ（最大 140 文字にサーバ側でトリム） |
| `progress` | Float | 0.0〜1.0（`normalize_progress` で正規化） |
| `updatedAt` | Integer | Unix 秒。更新の重複排除に利用 |

---

## HTTP エンドポイント

| メソッド | パス | 説明 |
|----------|------|------|
| GET | `/` | `/screen` へリダイレクト |
| GET | `/screen` | `index.html` を `text/html` で返す |
| GET | `/healthz` | ヘルスチェック（`ok`） |
| GET | `/state` | 現在の `STATE` を JSON で返す（読み取り専用） |
| GET | `/ws` | **WebSocket**（通常の HTTP では 400 `websocket required`） |
| GET | `/progress` | 進捗投稿（クエリでパラメータ。下記） |

### `GET /progress`

- **認証:** 環境変数 `PROGRESS_KEY` が空でなければ、クエリ `key` が一致しないと **403**。
- **パラメータ:** `who`（文字列）、`progress`（数値。1 超なら百分率として 100 で割る）、`message`（任意・空白正規化・最大 140 文字）。
- **処理:** `STATE` を更新し、`updatedAt` を `Time.now.to_i` にし、**接続中の全 WebSocket クライアントへ JSON をブロードキャスト**。
- **応答:** 成功時は本文 `ok`。不正な progress は **400**。

### `GET /ws`（WebSocket）

- 接続直後に **現在の `STATE` 全体を JSON で 1 通送信**。
- 以降、`/progress` 成功のたびに **同じ形の JSON** がブロードキャストされる。
- **上限:** 同時接続数 `MAX_WS_CLIENTS`（既定 500）。超過時はアップグレード前に **503**。
- **キープアライブ:** Faye 側 `ping: 15`（秒）。
- 送信失敗時は当該ソケットを `WS_CLIENTS` から除去。

---

## スクリーン（`index.html`）の挙動

- **URL:** `wss://` / `ws://` + `location.host` + `/ws` で接続（同一オリジン）。
- **受信:** 各メッセージを JSON パースし、`handleProgressPayload` に渡す。
  - `progress` で桜量スライダー相当の値を更新し、下部 `info` テキストを更新。
  - **トースト:** `updatedAt` が前回通知と同じならスキップ（再接続や重複配信での連打防止）。
  - 通知は **キュー**（約 5 秒表示・順番処理）。
- **再接続:** 切断時に **指数バックオフ**（1 秒開始、最大 30 秒）。意図的な `close` と古い接続の `close` が二重にスケジュールしないよう **世代番号**でガード。
- **デバッグログ:** `?screenDebug=0` または `localStorage sakurasakeScreenDebug=0` で `[sakurasake-screen]` ログを抑制。

---

## 環境変数

| 名前 | 役割 |
|------|------|
| `PROGRESS_KEY` | 設定時のみ `/progress` に `key` クエリ必須 |
| `PORT` | サーバが listen するポート（Docker / Fly 等） |
| `RACK_ENV` | `production` 推奨（本番 Docker では Dockerfile で設定） |

---

## 起動例

```bash
cd server
RACK_ENV=production bundle exec rackup -p 4567 -o 0.0.0.0 config.ru
```

### 進捗送信（curl・日本語は URL エンコード推奨）

```bash
curl -G "http://localhost:4567/progress" \
  --data-urlencode "who=test" \
  --data-urlencode "progress=0.3" \
  --data-urlencode "message=進捗できた"
```

`PROGRESS_KEY` がある場合は `&key=...` を追加。

---

## デプロイ・運用メモ

- **Fly.io 等:** WebSocket 対応はプラットフォーム依存だが、HTTP アップグレードを通せれば可（Fly の `http_service` で一般的に可）。
- **複数インスタンス:** `WS_CLIENTS` と `STATE` は **プロセスローカル**。スケールアウトすると **別マシンに接続したクライアントへは届かない**。必要なら Redis pub/sub 等で共有するか、スクリーン用は 1 インスタンスに寄せる。
- **SSE 大量ログ問題:** 旧実装の SSE + 開発サーバの組み合わせで観測された重複は、**WebSocket 一本化 + Puma 正規起動**で解消を意図。

---

## 付録: 当初の構想メモ（未実装）

初期の [`plan.md`](plan.md) には **Next.js + Firestore + p5.js** による別アーキテクチャ案（チーム別投稿、`config/settings.ts`、セキュリティルール等）が詳しく書かれていた。**現リポジトリの動く実装は上記の Sinatra + 単体 HTML + WebSocket に一致する。** Firebase 案を再開する場合は、データモデルと本書の `STATE`/REST を突き合わせて再設計すること。
