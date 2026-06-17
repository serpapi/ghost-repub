require "logger"

require_relative "config"
require_relative "rss_worker"

module Repub
  module ServerBoot
    module_function

    def logger
      $stdout.sync = true
      $stderr.sync = true

      Logger.new($stdout).tap do |logger|
        logger.level = Logger::INFO
        logger.formatter = proc do |_severity, _datetime, _progname, message|
          "#{message}\n"
        end
      end
    end

    def build_worker(logger:, trap_signals: true)
      RssWorker.new(
        rss_url: Config.rss_url,
        publishers_for_author_key: ->(author_key) { Config.publishers_for_author_key(author_key) },
        poll_interval: Config.poll_interval,
        rss_item_limit: Config.rss_item_limit,
        republish_after_days: Config.republish_after_days,
        logger: logger,
        trap_signals: trap_signals
      )
    end

    def log_startup(logger, mode:)
      logger.info("Repub server starting")
      logger.info("Mode: #{mode}")
      logger.info("RSS feed: #{Config.rss_url}")
      logger.info("Services: #{Config.enabled_services.join(", ")}")
      logger.info("Polling every #{Config.poll_interval} seconds")
      logger.info("Checking latest #{Config.rss_item_limit} RSS item(s)")
      logger.info("Republishing posts at least #{Config.republish_after_days} days old")
      logger.info("DEV.to organization ID: #{Config.devto_organization_id || "none"}")
      logger.info("DEV.to mode: #{Config.devto_published? ? "publish" : "draft"}")
    end

    def start_background_worker(logger:)
      if defined?(@worker_thread) && @worker_thread&.alive?
        logger.info("Repub background worker already running")
        return @worker_thread
      end

      log_startup(logger, mode: "rack background worker")

      worker = build_worker(logger: logger, trap_signals: false)
      @worker_thread = Thread.new do
        Thread.current.name = "repub-worker" if Thread.current.respond_to?(:name=)
        worker.run
      end
      @worker_thread.report_on_exception = true
      @worker_thread
    end
  end
end
