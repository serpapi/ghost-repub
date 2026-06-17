FROM ruby:4.0.1-alpine

WORKDIR /usr/src/app

RUN apk add --no-cache build-base git ca-certificates

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

RUN bundle exec ruby -c config.ru && \
    bundle exec ruby -c server.rb && \
    bundle exec ruby -c cli.rb && \
    bundle exec ruby -c lib/repub/config.rb && \
    bundle exec ruby -c lib/repub/rss_worker.rb && \
    bundle exec ruby -c lib/repub/server_boot.rb && \
    bundle exec ruby -c lib/repub/publishers/devto.rb

EXPOSE 80

CMD ["bundle", "exec", "rackup", "config.ru", "--host", "0.0.0.0", "--port", "80"]
