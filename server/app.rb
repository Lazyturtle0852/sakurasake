require "json"
require "sinatra"
require "faye/websocket"
require "uri"

set :bind, "0.0.0.0"

ROOT_DIR = File.expand_path("..", __dir__)
SCREEN_FILE = File.join(ROOT_DIR, "index.html")
PUBLIC_DIR = File.join(ROOT_DIR, "public")

set :public_folder, PUBLIC_DIR
set :static, true

PROGRESS_KEY = ENV["PROGRESS_KEY"]

STATE_MUTEX = Mutex.new
WS_CLIENTS_MUTEX = Mutex.new

MAX_CONTENT_LEN = 200
MAX_IMG_URL_LEN = 2048

STATE = {
  who: nil,
  content: nil,
  kind: nil,
  img: nil,
  from: nil,
  updatedAt: Time.now.to_i,
}

WS_CLIENTS = []

MAX_WS_CLIENTS = 500

def broadcast_ws!(payload_hash)
  data = JSON.generate(payload_hash)
  dead = []
  snapshot = WS_CLIENTS_MUTEX.synchronize { WS_CLIENTS.dup }
  snapshot.each do |ws|
    begin
      ws.send(data)
    rescue StandardError
      dead << ws
    end
  end
  return if dead.empty?
  WS_CLIENTS_MUTEX.synchronize { dead.each { |ws| WS_CLIENTS.delete(ws) } }
end

helpers do
  def json(data)
    content_type :json
    JSON.generate(data)
  end

  def require_key!
    return if PROGRESS_KEY.nil? || PROGRESS_KEY.empty?
    halt 403, "forbidden" unless params["key"] == PROGRESS_KEY
  end

  def normalize_content(raw, max_len = MAX_CONTENT_LEN)
    s = raw.to_s.gsub(/\s+/, " ").strip.slice(0, max_len)
    s.empty? ? nil : s
  end

  def validate_img_url(raw)
    s = raw.to_s.strip
    return nil if s.empty?
    halt 400, "invalid img" if s.length > MAX_IMG_URL_LEN
    u = URI.parse(s)
    halt 400, "invalid img" unless %w[http https].include?(u.scheme)
    s
  rescue URI::InvalidURIError
    halt 400, "invalid img"
  end

  def commit_state!(updates)
    snapshot = nil
    STATE_MUTEX.synchronize do
      updates.each { |k, v| STATE[k] = v }
      STATE[:updatedAt] = Time.now.to_i
      snapshot = STATE.dup
    end
    broadcast_ws!(snapshot)
  end
end

get "/" do
  redirect "/screen"
end

get "/screen" do
  content_type "text/html; charset=utf-8"
  send_file SCREEN_FILE
end

get "/healthz" do
  "ok"
end

get "/state" do
  snapshot = STATE_MUTEX.synchronize { STATE.dup }
  json(snapshot)
end

get "/ws" do
  halt 400, "websocket required" unless Faye::WebSocket.websocket?(env)

  accepted = false
  WS_CLIENTS_MUTEX.synchronize do
    if WS_CLIENTS.length < MAX_WS_CLIENTS
      accepted = true
    end
  end
  halt 503, "too many websocket connections" unless accepted

  ws = Faye::WebSocket.new(env, nil, ping: 15)
  WS_CLIENTS_MUTEX.synchronize { WS_CLIENTS << ws }

  initial = STATE_MUTEX.synchronize { STATE.dup }
  begin
    ws.send(JSON.generate(initial))
  rescue StandardError
    # ignore; onclose cleanup will handle
  end

  ws.on :close do |_event|
    WS_CLIENTS_MUTEX.synchronize { WS_CLIENTS.delete(ws) }
  end

  ws.on :error do |_event|
    WS_CLIENTS_MUTEX.synchronize { WS_CLIENTS.delete(ws) }
  end

  ws.rack_response
end

get "/like" do
  require_key!

  who = normalize_content(params["who"])
  content = normalize_content(params["content"])
  img = validate_img_url(params["img"])

  commit_state!(
    who: who,
    content: content,
    kind: "like",
    img: img,
    from: nil
  )
  "ok"
end

get "/post" do
  require_key!

  who = normalize_content(params["who"])
  content = normalize_content(params["content"])
  img = validate_img_url(params["img"])

  commit_state!(
    who: who,
    content: content,
    kind: "post",
    img: img,
    from: nil
  )
  "ok"
end

get "/comment" do
  require_key!

  who = normalize_content(params["who"])
  from = normalize_content(params["from"])
  content = normalize_content(params["content"])
  halt 400, "empty content" if content.nil?

  commit_state!(
    who: who,
    content: content,
    kind: "comment",
    img: nil,
    from: from
  )
  "ok"
end
