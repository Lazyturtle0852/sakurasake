require "json"
require "sinatra"
require "faye/websocket"

set :bind, "0.0.0.0"

ROOT_DIR = File.expand_path("..", __dir__)
SCREEN_FILE = File.join(ROOT_DIR, "index.html")
PUBLIC_DIR = File.join(ROOT_DIR, "public")

set :public_folder, PUBLIC_DIR
set :static, true

PROGRESS_KEY = ENV["PROGRESS_KEY"]

STATE_MUTEX = Mutex.new
WS_CLIENTS_MUTEX = Mutex.new

STATE = {
  who: nil,
  message: nil,
  progress: 0.0,
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

  def normalize_progress(raw)
    p = Float(raw)
    p = p / 100.0 if p > 1.0
    [[p, 0.0].max, 1.0].min
  rescue ArgumentError, TypeError
    nil
  end

  def require_key!
    return if PROGRESS_KEY.nil? || PROGRESS_KEY.empty?
    halt 403, "forbidden" unless params["key"] == PROGRESS_KEY
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

get "/progress" do
  require_key!

  who = params["who"].to_s
  message =
    params["message"]
      .to_s
      .gsub(/\s+/, " ")
      .strip
      .slice(0, 140)
  progress = normalize_progress(params["progress"])
  halt 400, "invalid progress" if progress.nil?

  snapshot = nil
  STATE_MUTEX.synchronize do
    STATE[:who] = who
    STATE[:message] = message.empty? ? nil : message
    STATE[:progress] = progress
    STATE[:updatedAt] = Time.now.to_i
    snapshot = STATE.dup
  end

  broadcast_ws!(snapshot)
  "ok"
end
