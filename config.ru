$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "dotenv/load"
require "repub/server_boot"

logger = Repub::ServerBoot.logger
Repub::ServerBoot.start_background_worker(logger: logger)

app = lambda do |_env|
  [
    200,
    { "content-type" => "text/plain; charset=utf-8" },
    ["repub rack app running\n"]
  ]
end

run app
