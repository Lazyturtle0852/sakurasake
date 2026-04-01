# frozen_string_literal: true

require "fileutils"
require "json"
require "pg"
require "time"

module Sakurasake
  class StaticExporter
    ROOT_DIR = File.expand_path("..", __dir__)
    INDEX_FILE = File.join(ROOT_DIR, "index.html")
    MODEL_FILE = File.join(ROOT_DIR, "screen-model.html")
    PUBLIC_DIR = File.join(ROOT_DIR, "public")
    DEFAULT_OUT_DIR = File.join(ROOT_DIR, "out", "static-export")
    STATIC_ORBIT_MAX = 100

    def self.run!
      new.run!
    end

    def initialize
      @database_url = ENV["DATABASE_URL"].to_s.strip
      @out_dir = File.expand_path(
        ENV.fetch("STATIC_EXPORT_OUT_DIR", DEFAULT_OUT_DIR),
        ROOT_DIR,
      )
    end

    def run!
      abort "DATABASE_URL is required for static export" if @database_url.empty?

      ensure_source_files!
      items = load_feed_items
      total_count = load_total_count
      model_manifest = build_model_manifest
      orbit_max = [items.length, STATIC_ORBIT_MAX].min
      display_items = sample_display_items(items, orbit_max)

      prepare_output_dir!
      write_json(File.join(@out_dir, "feed-snapshot.json"), {
        items: items,
        totalCount: total_count,
        database: true,
      })
      write_json(File.join(@out_dir, "models-manifest.json"), model_manifest)
      export_public_assets!

      bootstrap = {
        staticExport: true,
        exportedAt: Time.now.utc.iso8601,
        orbitMax: orbit_max,
        feed: {
          items: display_items,
          totalCount: total_count,
          database: true,
        },
        modelsManifest: model_manifest,
      }

      write_exported_html(INDEX_FILE, File.join(@out_dir, "index.html"), bootstrap)
      write_exported_html(MODEL_FILE, File.join(@out_dir, "screen-model.html"), bootstrap)

      puts "static export completed:"
      puts "  out_dir: #{@out_dir}"
      puts "  feed_items_total: #{items.length}"
      puts "  orbit_display_items: #{display_items.length}"
      puts "  total_count: #{total_count}"
      puts "  orbit_max: #{orbit_max}"
      puts "  model_files: #{model_manifest.fetch(:items, []).length}"
    end

    private

    def ensure_source_files!
      [INDEX_FILE, MODEL_FILE, PUBLIC_DIR].each do |path|
        next if File.exist?(path)

        abort "source not found: #{path}"
      end
    end

    def connection
      @connection ||= PG.connect(@database_url)
    end

    def load_feed_items
      result = connection.exec(<<~SQL)
        SELECT id, kind, who, "from", content, img, likes, created_at
        FROM feed_items
        ORDER BY created_at ASC, id ASC
      SQL

      result.map do |row|
        {
          id: row["id"].to_i,
          kind: row["kind"],
          who: row["who"],
          from: row["from"],
          content: row["content"],
          img: row["img"],
          likes: row["likes"].to_i,
          createdAt: row["created_at"]&.then { |t| t.is_a?(Time) ? t.utc.iso8601 : t.to_s },
        }
      end
    end

    def load_total_count
      result = connection.exec(<<~SQL)
        SELECT COUNT(*)::bigint AS n
        FROM feed_items
        WHERE kind IN ('post', 'comment')
      SQL
      result[0]["n"].to_i
    end

    def build_model_manifest
      items = Dir.glob(File.join(PUBLIC_DIR, "models", "*.glb"))
        .sort
        .map { |path| "./public/models/#{File.basename(path)}" }

      { items: items }
    end

    def sample_display_items(items, limit)
      return [] if items.empty? || limit <= 0

      items
        .sample([items.length, limit].min)
        .sort_by do |item|
          created_at = Time.parse(item.fetch(:createdAt, "").to_s).to_i rescue 0
          [created_at, item.fetch(:id, 0).to_i]
        end
    end

    def prepare_output_dir!
      FileUtils.mkdir_p(@out_dir)
    end

    def export_public_assets!
      export_public_dir = File.join(@out_dir, "public")
      FileUtils.rm_rf(export_public_dir) if File.exist?(export_public_dir)
      FileUtils.cp_r(PUBLIC_DIR, @out_dir)
    end

    def write_exported_html(source_path, destination_path, bootstrap)
      html = File.read(source_path)
      injected = inject_bootstrap!(html, bootstrap)
      File.write(destination_path, injected)
    end

    def inject_bootstrap!(html, bootstrap)
      payload = JSON.generate(bootstrap).gsub("</", "<\\/")
      script_tag = <<~HTML.chomp
        <script>
            window.__SAKURASAKE_STATIC_EXPORT__ = #{payload};
        </script>
      HTML

      injected = html.sub(
        "<script type=\"module\">",
        "#{script_tag}\n\n    <script type=\"module\">",
      )
      return injected unless injected == html

      abort "failed to inject static bootstrap into HTML"
    end

    def write_json(path, payload)
      File.write(path, JSON.pretty_generate(payload))
    end
  end
end
