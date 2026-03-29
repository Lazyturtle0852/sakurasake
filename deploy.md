# デプロイ手順（SSH 後）

ローカルで `main` に push 済みであることを前提とする。Apache / TLS / リバースプロキシの設定は初回のみで、**アプリの更新では通常は触らない**。

## 前提

- サーバー: Ubuntu（例: `root@<VMのIP>`）
- リポジトリの配置: `~/sakurasake`（このディレクトリで作業する）
- アプリは Docker コンテナ `sakurasake` が **ホストの `8080`** を公開している想定
- 外向きの HTTPS / WebSocket は Apache が終端し、バックエンドへプロキシする構成

## アプリの更新（毎回やる最小限）

```bash
cd ~/sakurasake
git pull
docker build -t sakurasake .
docker stop sakurasake
docker rm sakurasake
docker run -d -p 8080:8080 --name sakurasake sakurasake
```

- `server/Gemfile` や `Dockerfile` を変えた場合も、上記の `docker build` で依存関係まで含めて再構築される。
- コンテナ名・ポートを変えている場合は、`docker run` の `--name` と `-p` を環境に合わせる。

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
