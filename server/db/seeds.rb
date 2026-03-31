# frozen_string_literal: true

# 使い方（プロジェクトルートまたは server ディレクトリから）:
#   export DATABASE_URL="postgres://USER:PASS@localhost:5432/sakurasake"
#   cd server && bundle exec rake db:seed

require "pg"

url = ENV["DATABASE_URL"].to_s.strip
abort "DATABASE_URL が未設定です。例: export DATABASE_URL=postgres://localhost/sakurasake" if url.empty?

seed_count = ENV.fetch("SEED_COUNT", "300").to_i
seed_count = 0 if seed_count < 0

conn = PG.connect(url)

conn.transaction do |c|
  c.exec("TRUNCATE feed_items RESTART IDENTITY")

  people = ["太郎", "花子", "佐藤", "みんな", "高橋", "鈴木", "田中", "山本"].freeze
  phrases = [
    "桜がきれい！",
    "デモ準備できました",
    "会場が盛り上がってきた",
    "写真撮った？",
    "いま向かってます",
    "最高でした",
    "あとで合流しよう",
    "ありがとう！",
  ].freeze

  # created_at の新しい順が「post/comment混在」になるように、投入順と時刻を混ぜる。
  # これで `/feed?limit=200` でも kind が偏りにくくなる。
  (0...seed_count).each do |i|
    created_at = "now() - interval '#{seed_count - i} seconds'"
    is_post = (i % 2).zero?

    if is_post
      who = people[i % people.length]
      content = "#{phrases[i % phrases.length]} ##{i + 1}"
      img = (i % 12).zero? ? "https://picsum.photos/seed/sakurasake#{i}/480/320" : nil
      likes = i % 11
      c.exec_params(
        <<~SQL,
          INSERT INTO feed_items (kind, who, content, img, likes, created_at)
          VALUES ('post', $1, $2, $3, $4, #{created_at})
        SQL
        [who, content, img, likes],
      )
    else
      who = people[(i + 2) % people.length]
      from = people[i % people.length]
      content = "（コメント）#{phrases[i % phrases.length]} @#{who} ##{i + 1}"
      c.exec_params(
        <<~SQL,
          INSERT INTO feed_items (kind, who, "from", content, likes, created_at)
          VALUES ('comment', $1, $2, $3, 0, #{created_at})
        SQL
        [who, from, content],
      )
    end
  end
end

count = conn.exec("SELECT COUNT(*) FROM feed_items").getvalue(0, 0)
puts "feed_items に #{count} 件を投入しました。"
conn.close
