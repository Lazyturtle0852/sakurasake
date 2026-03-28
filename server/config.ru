require "faye/websocket"
Faye::WebSocket.load_adapter("puma")

require_relative "./app"

run Sinatra::Application
