# デプロイ手順（SSH 後）

ローカルで `main` に push 済みであることを前提とする。Apache / TLS / リバースプロキシの設定は初回のみで、**アプリの更新では通常は触らない**。

## 前提

- サーバー: Ubuntu（例: `root@<VMのIP>`）
- リポジトリの配置: `~/sakurasake`（**`docker-compose.yml` があるディレクトリで** `docker-compose` / `git pull` を実行する）
- **PostgreSQL** は `docker-compose.yml` の **`db` サービス**で起動し、アプリの **`DATABASE_URL`** で接続する
- 外向きの HTTPS / WebSocket は Apache が終端し、バックエンドへプロキシする構成（**アプリはホストの `8080`**）

## `docker compose` と `docker-compose`（プラグイン有無）

- **Docker Compose V2 プラグイン**が入っている環境では `docker compose`（スペース）が使える。
- **プラグイン未導入の VPS**では `docker: unknown command: docker compose` になる。次のいずれかで対応する。
  - [Docker 公式手順](https://docs.docker.com/engine/install/ubuntu/)で APT ソースを追加し、`docker-compose-plugin` を入れる。
  - または **`docker-compose`（ハイフン）** だけ入っている場合は、以降のコマンドを **`docker compose` → `docker-compose`** に読み替える。

本書の例は **`docker compose`** で書く。VPS では **`docker-compose`** に置き換えてよい。

## アプリの更新（毎回やる最小限・Compose 推奨）

```bash
cd ~/sakurasake
git pull
docker compose up -d --build
```

（`docker-compose` のみのサーバでは: `docker-compose up -d --build`）

- 初回起動時、**エントリポイント**が [`server/db/migrate.rb`](server/db/migrate.rb) でスキーマを適用してから `rackup` を起動する。
- `server/Gemfile` や `Dockerfile` を変えた場合も、上記でイメージが再ビルドされる。
- **単体コンテナのみ**運用する場合は `DATABASE_URL` を別途（マネージド DB 等）用意し、`docker run` に `-e DATABASE_URL=...` を付与する。

### 旧手順（DB なしの単体 `docker run` のみ）

歴史的な手順として、Compose 以前は次のようにしていた:

```bash
docker build -t sakurasake .
docker stop sakurasake && docker rm sakurasake
docker run -d -p 8080:8080 --name sakurasake sakurasake
```

**現在は DB 前提のため、本番では Compose を使う。** この旧手順だけでは **`db` が起動せず**、`DATABASE_URL` も無い。

### デプロイスクリプト例

- **`~/sakurasake` で実行する**（`~` 直下だけだと `docker-compose.yml` が見つからない）。
- 中身の例: `cd /root/sakurasake && git pull && docker compose up -d --build`（環境に合わせ `docker-compose` に）。

### 任意: ワンライナー化

同じ内容を `/root/deploy.sh` などにまとめ、`chmod +x` してから `./deploy.sh` で実行してもよい。

## Apache をいじったときだけ

VirtualHost（例: `/etc/apache2/sites-available/sakurasake.lazyta-toru.net-le-ssl.conf`）を変更した場合:

```bash
apache2ctl configtest
systemctl reload apache2
```

アプリのコード更新だけでは **reload は不要**（プロキシ先が `127.0.0.1:8080` のままなら）。バックエンドが落ちていると **503 Service Unavailable** になりやすい（`docker compose ps` で `app` / `db` が **Up** か確認）。

## 動作確認（サーバー上）

バックエンドが生きていれば WebSocket 昇格で `101` が返る:

```bash
curl --http1.1 -v \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://127.0.0.1:8080/ws"
```

外向き HTTPS 経由で問題がある場合は、Apache 側の WebSocket プロキシ設定やエラーログ（`500` など）を確認する。コンテナ単体は `127.0.0.1:8080` で `101` なのにドメインだけ失敗する場合は、**Apache の設定・reload** が原因になりやすい。

ゲートウェイの動作だけ見る場合（`PROGRESS_KEY` 未設定時）:

```bash
curl -sS -w "\nHTTP %{http_code}\n" "http://127.0.0.1:8080/post?who=test&content=probe"
```

## ログの見方（`docker-compose` v1 の注意）

**ハイフン付き `docker-compose`** では、オプションを **サービス名の前**に置く。

```bash
docker-compose logs --tail 80 app
```

`docker-compose logs app --tail 80` とすると、`--tail` がサービス名と誤解釈され **`No such service: --tail`** になることがある。

## PostgreSQL / `psql`（本番サーバ）

- ホスト（Ubuntu）に **`psql` は入っていない**ことが多い。DB コンテナ内の `psql` を使う。
- **対話モード**（`sakurasake=#`）が `docker compose exec -it db psql ...` で開けない SSH／端末では、**コンテナ名を明示した `docker exec`** が安定することがある。

```bash
cd ~/sakurasake
docker compose ps
docker exec -it sakurasake_db_1 psql -U sakurasake -d sakurasake
```

コンテナ名（例: `sakurasake_db_1`）は **`docker compose ps` の `Name` 列**で確認する（プロジェクト名・ディレクトリで変わる）。

- **対話が不要**なら（TTY なし）:

```bash
docker compose exec -T db psql -U sakurasake -d sakurasake -c '\dt'
docker compose exec -T db psql -U sakurasake -d sakurasake -c "SELECT COUNT(*) FROM feed_items;"
```

- 疑似端末を付けたい場合は、**SSH 接続に `-t` を付ける**（`ssh -t user@host`）と改善することがある。

## 付記（Glide / `PROGRESS_KEY`）

本番で環境変数 **`PROGRESS_KEY`** を設定している場合、`/like`・`/post`・`/comment` は **`key` クエリが一致しないと 403** となり DB に書かれない。Glide の URL に **`&key=...`** を付けるか、運用方針に合わせてキーを外す。
