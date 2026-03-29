#!/usr/bin/env ruby
# frozen_string_literal: true

require "pg"

ROOT = File.expand_path("..", __dir__)
sql_path = File.join(ROOT, "db", "migrate", "001_feed_items.sql")

url = ENV["DATABASE_URL"]
abort "DATABASE_URL is required for migrate" if url.nil? || url.empty?

conn = PG.connect(url)
begin
  conn.exec(File.read(sql_path))
  puts "migrate: ok (#{sql_path})"
ensure
  conn.close
end
