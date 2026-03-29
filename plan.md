# sakurasake — 仕様書（現行実装）

**キャッチコピー:** 「進捗を、会場の景色に変える」

Glide 等からのイベントが、メインスクリーンの Three.js シーン（トースト通知・任意で画像）に WebSocket でリアルタイム反映される。**リアルタイム経路は WebSocket のみ**（旧 SSE は廃止）。

**注意:** クエリの `progress` は **数値ではなく、進捗内容を表す文字列**である。桜の量（木の表示）は **本 HTTP 経路では変更しない**（スクリーン上のスライダーでローカルに調整可能）。

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
| `who` | string / nil | 表示名（いいね・投稿の主／コメントの宛先） |
| `message` | string / nil | メッセージ（コメント本文。最大 140 文字にサーバ側でトリム） |
| `progress` | string / nil | **進捗の内容**を表すラベル（数値ではない） |
| `kind` | string / nil | `"like"` / `"post"` / `"comment"`。未設定時はスクリーンはトーストを出さない |
| `img` | string / nil | 画像 URL（`http` / `https` のみ。like・投稿用） |
| `from` | string / nil | コメントの差出人 |
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
| GET | `/like` | いいね（Glide 想定） |
| GET | `/post` | 投稿 |
| GET | `/comment` | コメント |

### 共通（`/like`・`/post`・`/comment`）

- **認証:** 環境変数 `PROGRESS_KEY` が空でなければ、クエリ `key` が一致しないと **403**。
- **処理:** `STATE` を更新し、`updatedAt` を更新し、**接続中の全 WebSocket クライアントへ JSON をブロードキャスト**。
- **応答:** 成功時は本文 `ok`。

### `GET /like`

- **パラメータ:** `who`（任意）、`progress`（任意・**文字列**・進捗内容）、`img`（任意・画像 URL、`http` / `https` のみ。不正は **400**）。
- **STATE:** `kind` は `"like"`。`message`・`from` は `nil`。

### `GET /post`

- **パラメータ:** `/like` と同じ。
- **STATE:** `kind` は `"post"`。

### `GET /comment`

- **パラメータ:** `who`（宛先）、`from`（差出人・任意）、`message`（本文・必須。空は **400**）、`progress`（任意・文字列）。
- **STATE:** `kind` は `"comment"`。`img` は `nil`。

### `GET /ws`（WebSocket）

- 接続直後に **現在の `STATE` 全体を JSON で 1 通送信**。
- 以降、上記ゲートウェイ成功のたびに **同じ形の JSON** がブロードキャストされる。
- **上限:** 同時接続数 `MAX_WS_CLIENTS`（既定 500）。超過時はアップグレード前に **503**。
- **キープアライブ:** Faye 側 `ping: 15`（秒）。
- 送信失敗時は当該ソケットを `WS_CLIENTS` から除去。

---

## スクリーン（`index.html`）の挙動

- **URL:** `wss://` / `ws://` + `location.host` + `/ws` で接続（同一オリジン）。
- **受信:** 各メッセージを JSON パースし、`handleProgressPayload` に渡す。
  - **`kind` が無い**（初期状態など）: **トーストは出さない**（接続直後の空 STATE 対策）。下部 `info` は `who` / `content` 文字列で更新。
  - **`kind` あり:** トーストを表示（4領域の対応は下表）。like/post で `img` があるときはカード内に枠付きでサムネ表示。
  - **桜の量:** WebSocket の `content` からは **変更しない**（スライダーはローカル操作のみ）。

#### トーストカードの4領域（`kind` 別）

| `kind` | タイトル（`#toastWho`） | サブタイトル（`#toastMessage`） | 画像（`#toastImg`） | フッター（`#toastGiftNote`） |
|--------|-------------------------|--------------------------------|---------------------|------------------------------|
| `like` | `{who または だれか}にいいねがきた！` | `content`（空のときは「（メッセージはありません）」） | `img` があるとき | `{who}に桜が贈られました` 系 |
| `post` | `{who または だれか}が投稿した！` | 同上 | 同上 | 「という投稿がありました！」 |
| `comment` | `from` / `who` に応じた「誰から誰へ」行（長いときはタイトル用フォントをやや小さく） | `content` のみ（空のときは「（本文なし）」） | なし | 「コメントが贈られました」 |
  - **トースト:** `updatedAt` が前回通知と同じならスキップ（再接続や重複配信での連打防止）。
  - 通知は **キュー**（約 5 秒表示・順番処理）。
- **再接続:** 切断時に **指数バックオフ**（1 秒開始、最大 30 秒）。
- **デバッグログ:** `?screenDebug=0` または `localStorage sakurasakeScreenDebug=0` で `[sakurasake-screen]` ログを抑制。

---

## 環境変数

| 名前 | 役割 |
|------|------|
| `PROGRESS_KEY` | 設定時のみ `/like`・`/post`・`/comment` に `key` クエリ必須 |
| `PORT` | サーバが listen するポート（Docker / Fly 等） |
| `RACK_ENV` | `production` 推奨（本番 Docker では Dockerfile で設定） |

---

## 起動例

```bash
cd server
RACK_ENV=production bundle exec rackup -p 4567 -o 0.0.0.0 config.ru
```

### リクエスト例（curl・日本語は URL エンコード推奨）

いいね:

```bash
curl -G "http://localhost:4567/like" \
  --data-urlencode "who=太郎" \
  --data-urlencode "progress=設計レビュー完了" \
  --data-urlencode "key=YOUR_KEY"
```

投稿（画像あり）:

```bash
curl -G "http://localhost:4567/post" \
  --data-urlencode "who=花子" \
  --data-urlencode "progress=デモ直前" \
  --data-urlencode "img=https://example.com/photo.jpg" \
  --data-urlencode "key=YOUR_KEY"
```

コメント:

```bash
curl -G "http://localhost:4567/comment" \
  --data-urlencode "who=太郎" \
  --data-urlencode "from=花子" \
  --data-urlencode "message=がんばって！" \
  --data-urlencode "key=YOUR_KEY"
```

`PROGRESS_KEY` が未設定のときは `key` は不要。

---

## デプロイ・運用メモ

- **Fly.io 等:** WebSocket 対応はプラットフォーム依存だが、HTTP アップグレードを通せれば可（Fly の `http_service` で一般的に可）。
- **複数インスタンス:** `WS_CLIENTS` と `STATE` は **プロセスローカル**。スケールアウトすると **別マシンに接続したクライアントへは届かない**。必要なら Redis pub/sub 等で共有するか、スクリーン用は 1 インスタンスに寄せる。

---

## 付録: 当初の構想メモ（未実装）

旧版の本書には **Next.js + Firestore + p5.js** 案の記述があった。**現リポジトリの動く実装は Sinatra + 単体 HTML + WebSocket に一致する。**
