FROM ruby:3.3-slim

WORKDIR /app

RUN apt-get update -y && apt-get install -y --no-install-recommends \
  build-essential \
  && rm -rf /var/lib/apt/lists/*

COPY server/Gemfile ./server/Gemfile

RUN gem install bundler -v 2.5.22 && \
  bundle config set --local path vendor/bundle && \
  bundle install --gemfile ./server/Gemfile

COPY server ./server
COPY index.html ./index.html
COPY public ./public

ENV RACK_ENV=production

ENV BUNDLE_GEMFILE=/app/server/Gemfile

CMD ["sh", "-lc", "bundle exec rackup -p ${PORT:-8080} -o 0.0.0.0 server/config.ru"]

