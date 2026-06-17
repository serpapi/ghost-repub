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

logger.info("Repub server starting")
logger.info("RSS feed: #{Repub::Config.rss_url}")
logger.info("Services: #{Repub::Config.enabled_services.join(", ")}")
logger.info("Polling every #{Repub::Config.poll_interval} seconds")
logger.info("Checking latest #{Repub::Config.rss_item_limit} RSS item(s)")
logger.info("Republishing posts at least #{Repub::Config.republish_after_days} days old")
logger.info("DEV.to organization ID: #{Repub::Config.devto_organization_id || "none"}")
logger.info("DEV.to mode: #{Repub::Config.devto_published? ? "publish" : "draft"}")
logger.info("Press Ctrl+C to stop")
worker.run
