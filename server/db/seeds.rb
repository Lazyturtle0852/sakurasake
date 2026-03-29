# frozen_string_literal: true

# 使い方（プロジェクトルートまたは server ディレクトリから）:
#   export DATABASE_URL="postgres://USER:PASS@localhost:5432/sakurasake"
#   cd server && bundle exec rake db:seed

require "pg"

url = ENV["DATABASE_URL"].to_s.strip
abort "DATABASE_URL が未設定です。例: export DATABASE_URL=postgres://localhost/sakurasake" if url.empty?

conn = PG.connect(url)

conn.transaction do |c|
  c.exec("TRUNCATE feed_items RESTART IDENTITY")

  # 投稿（likes はいいね発光の確認用）
  posts = [
    { who: "太郎", content: "設計レビュー完了 🎉", img: nil, likes: 0,
      at: "now() - interval '3 hours'" },
    { who: "花子", content: "デモ直前、最終調整中", img: "https://picsum.photos/seed/sakurasake1/480/320", likes: 3,
      at: "now() - interval '2 hours'" },
    { who: "佐藤", content: "会場の雰囲気最高です", img: nil, likes: 7,
      at: "now() - interval '90 minutes'" },
    { who: "みんな", content: "桜、きれい…！", img: nil, likes: 1,
      at: "now() - interval '1 hour'" },
  ]

  posts.each do |p|
    c.exec_params(
      <<~SQL,
        INSERT INTO feed_items (kind, who, content, img, likes, created_at)
        VALUES ('post', $1, $2, $3, $4, #{p[:at]})
      SQL
      [p[:who], p[:content], p[:img], p[:likes]],
    )
  end

  # コメント（宛先 who は既存の投稿者と揃えるとわかりやすい）
  comments = [
    { who: "太郎", from: "花子", content: "おめでとう！続きもがんばって", at: "now() - interval '2 hours 30 minutes'" },
    { who: "花子", from: "佐藤", content: "スライド共有ありがとう", at: "now() - interval '2 hours 15 minutes'" },
    { who: "佐藤", from: "みんな", content: "🌸 またあとで！", at: "now() - interval '45 minutes'" },
    { who: "みんな", from: "太郎", content: "今日はありがとうございました", at: "now() - interval '30 minutes'" },
  ]

  comments.each do |r|
    c.exec_params(
      <<~SQL,
        INSERT INTO feed_items (kind, who, "from", content, likes, created_at)
        VALUES ('comment', $1, $2, $3, 0, #{r[:at]})
      SQL
      [r[:who], r[:from], r[:content]],
    )
  end
end

count = conn.exec("SELECT COUNT(*) FROM feed_items").getvalue(0, 0)
puts "feed_items に #{count} 件を投入しました。"
conn.close
