#!/usr/bin/env ruby
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "dotenv/load"
require "repub/server_boot"

logger = Repub::ServerBoot.logger
worker = Repub::ServerBoot.build_worker(logger: logger)

Repub::ServerBoot.log_startup(logger, mode: "standalone")
logger.info("Press Ctrl+C to stop")
worker.run
