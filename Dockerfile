FROM ruby:3.3-slim

WORKDIR /app

RUN apt-get update -y && apt-get install -y --no-install-recommends \
  build-essential \
  libpq-dev \
  libpq5 \
  && rm -rf /var/lib/apt/lists/*

# ソースをコピーしたあと bundle install（先に bundle だけ COPY すると、後続の COPY server で vendor が上書きされ gem が消える）
COPY server ./server

RUN gem install bundler -v 2.5.22 && \
  cd server && \
  bundle config set --local path vendor/bundle && \
  bundle install

COPY index.html ./index.html
COPY screen-model.html ./screen-model.html
COPY public ./public
COPY bin ./bin
COPY docker-entrypoint.sh ./docker-entrypoint.sh

RUN chmod +x /app/docker-entrypoint.sh /app/bin/export-static

ENV RACK_ENV=production

ENV BUNDLE_GEMFILE=/app/server/Gemfile

ENTRYPOINT ["/app/docker-entrypoint.sh"]
