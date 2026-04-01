# frozen_string_literal: true

require "fileutils"
require "json"
require "pg"
require "time"
require "digest/sha1"

module Sakurasake
  class StaticExporter
    ROOT_DIR = File.expand_path("..", __dir__)
    INDEX_FILE = File.join(ROOT_DIR, "index.html")
    MODEL_FILE = File.join(ROOT_DIR, "screen-model.html")
    PUBLIC_DIR = File.join(ROOT_DIR, "public")
    DEFAULT_OUT_DIR = File.join(ROOT_DIR, "out", "static-export")
    STATIC_ORBIT_MAX = 100
    DEFAULT_NETLIFY_OUT_DIR_SUFFIX = "-netlify"

    def self.run!
      new.run!
    end

    def initialize
      @database_url = ENV["DATABASE_URL"].to_s.strip
      @out_dir = File.expand_path(
        ENV.fetch("STATIC_EXPORT_OUT_DIR", DEFAULT_OUT_DIR),
        ROOT_DIR,
      )
      @netlify_out_dir = File.expand_path(
        ENV.fetch("STATIC_NETLIFY_OUT_DIR", "#{@out_dir}#{DEFAULT_NETLIFY_OUT_DIR_SUFFIX}"),
        ROOT_DIR,
      )
      @basic_auth_user = ENV["STATIC_BASIC_AUTH_USER"].to_s
      @basic_auth_password = ENV["STATIC_BASIC_AUTH_PASSWORD"].to_s
      @basic_auth_realm = ENV.fetch("STATIC_BASIC_AUTH_REALM", "Sakurasake Export")
      @basic_auth_htpasswd_path = ENV["STATIC_BASIC_AUTH_HTPASSWD_PATH"].to_s.strip
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
      write_basic_auth_files! if basic_auth_enabled?
      write_netlify_export_project!

      puts "static export completed:"
      puts "  out_dir: #{@out_dir}"
      puts "  netlify_out_dir: #{@netlify_out_dir}"
      puts "  feed_items_total: #{items.length}"
      puts "  orbit_display_items: #{display_items.length}"
      puts "  total_count: #{total_count}"
      puts "  orbit_max: #{orbit_max}"
      puts "  model_files: #{model_manifest.fetch(:items, []).length}"
      if basic_auth_enabled?
        puts "  basic_auth: enabled"
        puts "  basic_auth_user: #{@basic_auth_user}"
        puts "  auth_user_file: #{resolved_htpasswd_path}"
      else
        puts "  basic_auth: disabled"
      end
    end

    private

    def ensure_source_files!
      [INDEX_FILE, MODEL_FILE, PUBLIC_DIR].each do |path|
        next if File.exist?(path)

        abort "source not found: #{path}"
      end
      validate_basic_auth_env!
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

    def validate_basic_auth_env!
      user_present = !@basic_auth_user.empty?
      password_present = !@basic_auth_password.empty?
      return if !user_present && !password_present
      return if user_present && password_present

      abort "STATIC_BASIC_AUTH_USER and STATIC_BASIC_AUTH_PASSWORD must both be set"
    end

    def basic_auth_enabled?
      !@basic_auth_user.empty? && !@basic_auth_password.empty?
    end

    def resolved_htpasswd_path
      return @basic_auth_htpasswd_path unless @basic_auth_htpasswd_path.empty?

      File.join(@out_dir, ".htpasswd")
    end

    def write_basic_auth_files!
      write_htpasswd_file!
      write_htaccess_file!
    end

    def write_htpasswd_file!
      File.write(
        File.join(@out_dir, ".htpasswd"),
        "#{@basic_auth_user}:#{apache_sha1_hash(@basic_auth_password)}\n",
      )
    end

    def write_htaccess_file!
      html_files = Dir.glob(File.join(@out_dir, "*.html"))
        .map { |path| File.basename(path) }
        .sort
      return if html_files.empty?

      request_targets = html_files.map { |name| Regexp.escape(name) }
      request_targets.unshift("") if html_files.include?("index.html")
      request_pattern = "^(?:#{request_targets.join("|")})$"

      content = <<~HTACCESS
        RewriteEngine On
        RewriteRule #{request_pattern} - [E=SAKURASAKE_ROOT_HTML_AUTH:1]

        AuthType Basic
        AuthName "#{escape_htaccess_string(@basic_auth_realm)}"
        AuthUserFile "#{escape_htaccess_string(resolved_htpasswd_path)}"

        <RequireAny>
            Require expr %{ENV:SAKURASAKE_ROOT_HTML_AUTH} != '1'
            Require valid-user
        </RequireAny>
      HTACCESS

      File.write(File.join(@out_dir, ".htaccess"), content)
    end

    def write_netlify_export_project!
      FileUtils.rm_rf(@netlify_out_dir) if File.exist?(@netlify_out_dir)
      FileUtils.mkdir_p(@netlify_out_dir)

      site_dir = File.join(@netlify_out_dir, "site")
      FileUtils.mkdir_p(site_dir)
      Dir.children(@out_dir).each do |entry|
        FileUtils.cp_r(File.join(@out_dir, entry), File.join(site_dir, entry))
      end

      edge_functions_dir = File.join(@netlify_out_dir, "netlify", "edge-functions")
      FileUtils.mkdir_p(edge_functions_dir)
      File.write(File.join(edge_functions_dir, "root-basic-auth.js"), netlify_basic_auth_edge_function)
      File.write(File.join(@netlify_out_dir, "netlify.toml"), netlify_toml)
    end

    def protected_root_html_paths
      html_files = Dir.glob(File.join(@out_dir, "*.html"))
        .map { |path| File.basename(path) }
        .sort

      html_files.each_with_object([]) do |name, paths|
        stem = name.sub(/\.html\z/, "")
        if name == "index.html"
          paths << "/"
          paths << "/index.html"
        else
          paths << "/#{stem}"
          paths << "/#{stem}/"
          paths << "/#{name}"
        end
      end.uniq
    end

    def netlify_basic_auth_edge_function
      <<~JS
        function parseBasicAuthorization(headerValue) {
            if (!headerValue || typeof headerValue !== "string") return null;
            const match = headerValue.match(/^Basic\\s+(.+)$/i);
            if (!match) return null;

            try {
                const decoded = atob(match[1]);
                const separatorIndex = decoded.indexOf(":");
                if (separatorIndex < 0) return null;
                return {
                    user: decoded.slice(0, separatorIndex),
                    password: decoded.slice(separatorIndex + 1),
                };
            } catch (_) {
                return null;
            }
        }

        function escapeRealm(value) {
            return String(value ?? "").replace(/["\\\\]/g, "\\\\$&");
        }

        export default async (request, context) => {
            const user = Netlify.env.get("STATIC_BASIC_AUTH_USER");
            const password = Netlify.env.get("STATIC_BASIC_AUTH_PASSWORD");
            const realm = Netlify.env.get("STATIC_BASIC_AUTH_REALM") || "Sakurasake Export";

            if (!user || !password) {
                return context.next();
            }

            const credentials = parseBasicAuthorization(request.headers.get("authorization"));
            if (credentials && credentials.user === user && credentials.password === password) {
                return context.next();
            }

            return new Response("Authentication required", {
                status: 401,
                headers: {
                    "WWW-Authenticate": `Basic realm="${escapeRealm(realm)}"`,
                    "Cache-Control": "no-store",
                },
            });
        };

        export const config = {
            path: #{JSON.pretty_generate(protected_root_html_paths)},
        };
      JS
    end

    def netlify_toml
      <<~TOML
        [build]
          publish = "site"
          edge_functions = "netlify/edge-functions"
      TOML
    end

    def apache_sha1_hash(password)
      "{SHA}#{[Digest::SHA1.digest(password)].pack("m0")}"
    end

    def escape_htaccess_string(value)
      value.to_s.gsub(/["\\]/, "\\\\\\&")
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
