## sakurasake

会場スクリーン（`/screen`）に **投稿・コメントが桜として表示**され、更新は **WebSocket** でリアルタイム同期される小さなアプリです。  
バックエンドは Sinatra、DB は Postgres（`feed_items`）を使います。

## 構成（ざっくり）

- `index.html`: スクリーン表示（Three.js）。`/feed`で初期ロード、`/ws`で更新を購読
- `server/app.rb`: Sinatra アプリ（HTTP + WebSocket）
- `server/db/migrate/001_feed_items.sql`: テーブル定義
- `docker-compose.yml`: `app`(Ruby) + `db`(Postgres) を起動

## Docker（推奨）での起動方法

前提:
- Docker Desktop（またはDocker Engine）と`docker compose`が使えること

### 1) 環境変数の用意（任意）

通常は`docker-compose.yml`内で`DATABASE_URL`を渡しているため、ローカル起動に`.env`は必須ではありません。

必要に応じて`.env.example`をコピーしてください。

```bash
cp .env.example .env
```

### 2) 起動

```bash
docker compose up --build
```

### 3) アクセス

- `http://localhost:8080`

### 4) seed データ投入（任意）

スクリーンの見た目を確認するために、投稿・コメントのダミーデータを投入できます。

- **注意**: `feed_items` を **TRUNCATE（全削除）** して入れ直します
- **件数**: 環境変数 `SEED_COUNT`（未指定は 300）

Docker 起動中に実行:

```bash
docker compose exec app bundle exec rake -f server/Rakefile db:seed
```

件数を指定したい場合:

```bash
docker compose exec -e SEED_COUNT=80 app bundle exec rake -f server/Rakefile db:seed
```

### 補足

- `db`: Postgres 16（データはDocker volume `pgdata` に永続化）
- `app`: 起動時に `server/db/migrate.rb` を実行してからRackサーバを起動します（`docker-entrypoint.sh`）

## API

このアプリは **JSON API + WebSocket** でスクリーンを更新します。  
`PROGRESS_KEY` を環境変数で設定している場合、投稿系エンドポイントは `?key=...` が一致しないと **403** になります（`server/app.rb` の `require_key!`）。

### HTTP

- **GET `/healthz`**
  - **用途**: 死活監視
  - **レスポンス**: `ok`

- **GET `/screen`**
  - **用途**: スクリーン表示（HTML）

- **GET `/feed?limit=80`**
  - **用途**: スクリーン初期同期用のフィード（直近の投稿・コメント）
  - **パラメータ**:
    - `limit`: 1〜200（未指定は 80）
  - **レスポンス**: `{ items: FeedItem[], database: boolean }`

- **GET `/post`**
  - **用途**: 投稿を作成し、state/WSへブロードキャスト
  - **想定クエリ**:
    - `who`: 投稿者（任意・200文字までに正規化）
    - `content`: 本文（任意・200文字までに正規化）
    - `img`: 画像URL（任意・http/httpsのみ、最大 2048 文字）
    - `key`: `PROGRESS_KEY` 設定時のみ必要
  - **レスポンス**: `302` で `/screen` にリダイレクト
  - **例**:

```bash
curl -i "http://localhost:8080/post?who=太郎&content=桜がきれい！"
```

- **GET `/comment`**
  - **用途**: コメントを作成し、state/WSへブロードキャスト
  - **想定クエリ**:
    - `who`: 宛先（任意・200文字までに正規化）
    - `from`: 送り主（任意・200文字までに正規化）
    - `content`: 本文（必須。空だと `400 empty content`）
    - `key`: `PROGRESS_KEY` 設定時のみ必要
  - **レスポンス**: `302` で `/screen` にリダイレクト
  - **例**:

```bash
curl -i "http://localhost:8080/comment?from=花子&who=太郎&content=見てるよ！"
```

- **GET `/like`**
  - **用途**: 直近の一致する投稿（`who`+`content`）の `likes` を +1 し、state/WSへブロードキャスト
  - **想定クエリ**:
    - `who`: 対象投稿の `who`（一致判定に使用）
    - `content`: 対象投稿の `content`（一致判定に使用）
    - `img`: 表示用の画像URL（任意）
    - `key`: `PROGRESS_KEY` 設定時のみ必要
  - **レスポンス**: `302` で `/screen` にリダイレクト
  - **例**:

```bash
curl -i "http://localhost:8080/like?who=太郎&content=桜がきれい！"
```

### WebSocket

- **GET `/ws`**
  - **用途**: スクリーンが state 更新を購読
  - **送信されるメッセージ**: `STATE` の JSON（`/state` と同形）。接続直後に初期状態が 1 回送られ、その後更新のたびにブロードキャストされます。

## DB スキーマ（簡易）

### `feed_items`

投稿・コメントのフィード。`kind` が `post` と `comment` のみを持ちます（SQL の CHECK 制約）。

- `id`: BIGSERIAL（主キー）
- `kind`: TEXT NOT NULL（`post` / `comment`）
- `who`: TEXT（投稿者 or コメント宛先）
- `from`: TEXT（コメント送り主。カラム名は `"from"`）
- `content`: TEXT
- `img`: TEXT（投稿画像URL）
- `likes`: INTEGER NOT NULL DEFAULT 0（投稿のいいね数。コメントは基本 0）
- `created_at`: TIMESTAMPTZ NOT NULL DEFAULT now()

インデックス:
- `idx_feed_items_created_at`（`created_at DESC`）
- `idx_feed_items_post_match`（`kind, who, content, created_at DESC`：`/like` の一致探索用）

### 停止 / 片付け

```bash
docker compose down
```

DBデータも削除したい場合:

```bash
docker compose down -v
```
