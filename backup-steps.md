# DBバックアップ手順（本番 ConoHa / Docker / Postgres・手動）

このドキュメントは、**本番VM（ConoHa）上の Docker で稼働している Postgres** のDBバックアップを、**短期間（例：4日間）だけ手動で確実に取る**ための手順書です。

- **バックアップ形式**: `pg_dump` の **CUSTOM形式**（`.dump`）
- **復元ツール**: `pg_restore`
- **オフサイト保管**: あなたのPCへ `scp` で退避
- **IP/ホスト名**: 伏せています（`<PROD_HOST>` に置き換えてください）

---

## 前提

- 本番VMへSSHログインできる（例：`ssh root@<PROD_HOST>`）
- 本番VMで `docker` が使える
- Postgresコンテナが起動している
  - 例: `sakurasake-db-1`（実環境に合わせて読み替え）
- ローカル（PC）で `pg_restore` が使える（Postgresクライアント一式）

---

## 1) 本番VM側：バックアップ（dump作成）

### 1-1. 本番VMへログイン（PCから）

```bash
ssh root@<PROD_HOST>
```

### 1-2. バックアップ保存ディレクトリ作成（初回のみ）

```bash
mkdir -p ~/db-backups
```

### 1-3. Postgresコンテナ名を確認

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

この手順書では以降、コンテナ名を `sakurasake-db-1` として説明します。違う場合は読み替えてください。

### 1-4. dump作成（毎回これを実行）

```bash
docker exec -i sakurasake-db-1 sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > ~/db-backups/sakurasake-$(date +%F-%H%M).dump
```

### 1-5. できたか確認（ファイル生成）

```bash
ls -lh ~/db-backups/
```

---

## 2) PC側：バックアップ回収（scp）

### 2-1. 保存先ディレクトリ作成（初回のみ）

```bash
mkdir -p ~/sakurasake-backups
```

### 2-2. 本番VMからdumpをコピー（毎回）

```bash
scp root@<PROD_HOST>:~/db-backups/sakurasake-YYYY-MM-DD-HHMM.dump ~/sakurasake-backups/
```

※ `YYYY-MM-DD-HHMM` は、VM側で作ったファイル名に合わせます（`ls -lh ~/db-backups/` で確認）。

---

## 3) 「バックアップできてる？」のチェック方法（重要）

バックアップの「できてる」は段階があります。**最低ライン → 推奨 → 最強** の順で紹介します。

### 3-1. 最低ライン：ファイルが作られていて、サイズが0じゃない

本番VM側:

```bash
ls -lh ~/db-backups/
```

PC側:

```bash
ls -lh ~/sakurasake-backups/
```

### 3-2. 推奨：`pg_restore --list` が通る（壊れてないチェック）

PC側:

```bash
pg_restore --list ~/sakurasake-backups/sakurasake-YYYY-MM-DD-HHMM.dump | head
```

期待する出力の例:

- `Format: CUSTOM`
- `Dumped from database version: ...`

ここで `pg_restore: error:` が出なければ、**少なくともファイルは壊れていない**可能性が高いです。

### 3-3. 最強（推奨）：実際にリストアして読めることを確認（復元テスト）

「ファイルがある/壊れてない」だけだと、**中身が期待通りか**までは保証できません。可能なら1回だけ、ローカルや検証用DBに復元テストすると安心です。

#### 方法A: ローカルのPostgresに復元（PostgresがPCに入っている場合）

```bash
createdb sakurasake_restore
pg_restore -d sakurasake_restore ~/sakurasake-backups/sakurasake-YYYY-MM-DD-HHMM.dump
```

#### 方法B: Dockerで一時Postgresを立てて復元（ローカルにPostgresが無い場合）

```bash
docker run --rm -d --name sakurasake-restore-check -e POSTGRES_PASSWORD=pass -e POSTGRES_DB=sakurasake_restore -p 15432:5432 postgres:16-alpine
```

復元:

```bash
PGPASSWORD=pass pg_restore -h 127.0.0.1 -p 15432 -U postgres -d sakurasake_restore ~/sakurasake-backups/sakurasake-YYYY-MM-DD-HHMM.dump
```

確認（例：テーブル一覧）:

```bash
PGPASSWORD=pass psql -h 127.0.0.1 -p 15432 -U postgres -d sakurasake_restore -c '\dt'
```

終わったら停止:

```bash
docker stop sakurasake-restore-check
```

---

## 4) よくあるエラーと対処

### 4-1. `No such file or directory`（VM側で dump 作成時）

例:

> `... > ~/db-backups/...dump: No such file or directory`

対処:

```bash
mkdir -p ~/db-backups
```

### 4-2. `No such file or directory`（PC側で `pg_restore` 実行時）

原因: `scp` で保存したディレクトリと、`pg_restore` で参照しているディレクトリが違う。

対処: `scp` 先（例：`~/sakurasake-backups/`）を正しく指定する。

---

## 5) 片付け（任意）

短期運用で不要なら、本番VM側のdumpを消す（**PCへの回収後に**）:

```bash
rm -f ~/db-backups/*.dump
```



## 消す方法
docker exec -it sakurasake-db-1 sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "TRUNCATE TABLE feed_items RESTART IDENTITY;"'
