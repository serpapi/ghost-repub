#!/usr/bin/env ruby
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "dotenv/load"
require "logger"
require "repub/config"
require "repub/rss_worker"

logger = Logger.new($stdout)
logger.level = Logger::INFO
logger.formatter = proc do |_severity, _datetime, _progname, message|
  "#{message}\n"
end

worker = Repub::RssWorker.new(
  rss_url: Repub::Config.rss_url,
  publishers_for_author_key: ->(author_key) { Repub::Config.publishers_for_author_key(author_key) },
  poll_interval: Repub::Config.poll_interval,
  rss_item_limit: Repub::Config.rss_item_limit,
  republish_after_days: Repub::Config.republish_after_days,
  logger: logger
)

logger.info("Starting repub server with services=#{Repub::Config.enabled_services.join(",")} rss_url=#{Repub::Config.rss_url} rss_item_limit=#{Repub::Config.rss_item_limit} republish_after_days=#{Repub::Config.republish_after_days}")
worker.run
