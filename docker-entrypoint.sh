#!/bin/sh
set -e
cd /app
bundle exec ruby server/db/migrate.rb
exec bundle exec rackup -p "${PORT:-8080}" -o 0.0.0.0 server/config.ru
