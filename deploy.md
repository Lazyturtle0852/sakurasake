# デプロイ手順（SSH 後）

ローカルで `main` に push 済みであることを前提とする。Apache / TLS / リバースプロキシの設定は初回のみで、**アプリの更新では通常は触らない**。

## 前提

- サーバー: Ubuntu（例: `root@<VMのIP>`）
- リポジトリの配置: `~/sakurasake`（このディレクトリで作業する）
- **PostgreSQL** は `docker-compose.yml` の **`db` サービス**で起動し、アプリの **`DATABASE_URL`** で接続する
- 外向きの HTTPS / WebSocket は Apache が終端し、バックエンドへプロキシする構成（**アプリはホストの `8080`**）

## アプリの更新（毎回やる最小限・Compose 推奨）

```bash
cd ~/sakurasake
git pull
docker compose up -d --build
```

- 初回起動時、**エントリポイント**が [`server/db/migrate.rb`](server/db/migrate.rb) でスキーマを適用してから `rackup` を起動する。
- `server/Gemfile` や `Dockerfile` を変えた場合も、上記でイメージが再ビルドされる。
- **単体コンテナのみ**運用する場合は `DATABASE_URL` を別途（マネージド DB 等）用意し、`docker run` に `-e DATABASE_URL=...` を付与する。

### 旧手順（DB なしの単体 `docker run` のみ）

歴史的な手順として、リポジトリに Compose が無い環境では次のようにしていた:

```bash
docker build -t sakurasake .
docker stop sakurasake
docker rm sakurasake
docker run -d -p 8080:8080 --name sakurasake sakurasake
```

**現在は DB 前提のため、本番では `docker compose` と `DATABASE_URL`（Compose 内なら自動）を使うことを推奨する。**

### 任意: ワンライナー化

同じ内容を `/root/deploy.sh` などにまとめ、`chmod +x` してから `./deploy.sh` で実行してもよい。

## Apache をいじったときだけ

VirtualHost（例: `/etc/apache2/sites-available/sakurasake.lazyta-toru.net-le-ssl.conf`）を変更した場合:

```bash
apache2ctl configtest
systemctl reload apache2
```

アプリのコード更新だけでは **reload は不要**（プロキシ先が `127.0.0.1:8080` のままなら）。

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

### DB 確認（Compose 利用時）

```bash
docker compose exec db psql -U sakurasake -d sakurasake -c "SELECT kind, who, content, likes FROM feed_items ORDER BY id DESC LIMIT 10;"
```
