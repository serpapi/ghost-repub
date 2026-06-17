#!/usr/bin/env ruby
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "dotenv/load"
require "repub/config"
require "repub/post_extractor"
require "repub/publishers/devto"

post_to_devto = ARGV.delete("--devto")
publish_to_devto = ARGV.delete("--publish")
abort "--publish requires --devto" if publish_to_devto && !post_to_devto

url = ARGV[0]
abort "Usage: ruby cli.rb [--devto] [--publish] <post-url>" unless url

post = Repub::PostExtractor.call(url)
filename = "#{post.slug}.md"
File.write(filename, post.frontmatter(published: publish_to_devto) + "\n" + post.markdown)
puts "Saved to #{filename}"

if post_to_devto
  api_key = ENV["DEVTO_API_KEY"]
  abort "Set DEVTO_API_KEY to post to DEV.to" if api_key.nil? || api_key.empty?

  publisher = Repub::Publishers::Devto.new(
    api_key: api_key,
    organization_id: Repub::Config.devto_organization_id,
    published: publish_to_devto
  )

  devto_article = publisher.publish(post)
  status = publish_to_devto ? "published article" : "draft"
  puts "Created DEV.to #{status}: #{devto_article["url"]}"
end
