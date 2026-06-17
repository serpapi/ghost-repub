require "logger"
require "nokogiri"
require "open-uri"
require "rss"
require "set"
require "time"

require_relative "post_extractor"

module Repub
  class RssWorker
    FeedItem = Struct.new(:url, :title, :author_name, :published_at, keyword_init: true)

    def initialize(rss_url:, publishers_for_author_key:, poll_interval:, rss_item_limit:, republish_after_days:, logger: Logger.new($stdout), trap_signals: true)
      @rss_url = rss_url
      @publishers_for_author_key = publishers_for_author_key
      @poll_interval = poll_interval
      @rss_item_limit = rss_item_limit
      @republish_after_days = republish_after_days
      @logger = logger
      @trap_signals = trap_signals
      @seen = Hash.new { |hash, key| hash[key] = Set.new }
      @publishers_by_author_key = {}
      @author_keys_by_url = {}
      @stop = false
    end

    def run
      trap_signals if @trap_signals

      loop do
        begin
          process_feed
        rescue StandardError => e
          @logger.error("Feed processing failed: #{e.class}: #{e.message}")
        end
        break if @stop

        @logger.info("Sleeping #{@poll_interval}s")
        sleep @poll_interval
      end
    end

    def process_feed
      @logger.info("Fetching RSS: #{@rss_url}")
      items = rss_items(@rss_url)
      @logger.info("Found #{items.length} RSS item(s); reposting only items at least #{@republish_after_days} days old")

      items.reverse_each do |item|
        process_item(item)
      rescue StandardError => e
        @logger.error("RSS item #{item.url} failed: #{e.class}: #{e.message}")
      end
    end

    private

    def process_item(item)
      author_name = item.author_name
      if author_name.nil? || author_name.empty?
        @logger.warn("No RSS author for #{item.url}; skipping")
        return
      end

      author_key = author_key_for_item(item)
      unless author_key
        @logger.warn("No blog author username for #{item.url}; skipping")
        return
      end

      publishers = publishers_for_author_key(author_key)
      configured_publishers = publishers.select(&:configured?)

      (publishers - configured_publishers).each do |publisher|
        log_skip(item, publisher, "missing token")
      end

      return if configured_publishers.empty?

      unless old_enough?(item)
        configured_publishers.each { |publisher| log_skip(item, publisher, "too new") }
        return
      end

      if @seen[author_key].include?(item.url)
        @logger.info("Already saw #{item.url} during this run; skipping")
        return
      end

      already_published_publishers = configured_publishers.select { |publisher| already_published_url?(publisher, item.url) }
      already_published_publishers.each do |publisher|
        log_skip(item, publisher, "already published")
      end

      pending_publishers = configured_publishers - already_published_publishers
      if pending_publishers.empty?
        @seen[author_key].add(item.url)
        return
      end

      @logger.info("Extracting #{item.url} for #{author_name}")
      post = PostExtractor.call(item.url)
      @seen[author_key].add(item.url)
      @seen[author_key].add(post.canonical_url)

      pending_publishers.each do |publisher|
        publisher_key = "#{author_key}:#{publisher.name}"

        if @seen[publisher_key].include?(post.canonical_url) || publisher.already_published?(post)
          log_skip(post, publisher, "already published")
          next
        end

        @logger.info("Republishing #{article_label(post)} to #{publisher.name}")
        result = publisher.publish(post)
        @seen[publisher_key].add(post.canonical_url)
        @logger.info("#{publisher.name}: created #{result["url"] || result["id"]}")
      rescue StandardError => e
        @logger.error("#{publisher.name}: failed for #{post.canonical_url}: #{e.class}: #{e.message}")
      end
    end

    def publishers_for_author_key(author_key)
      @publishers_by_author_key[author_key] ||= @publishers_for_author_key.call(author_key)
    end

    def author_key_for_item(item)
      @author_keys_by_url[item.url] ||= begin
        html = URI.open(item.url).read
        doc = Nokogiri::HTML(html)
        href = doc.css("a[href*='/blog/author/']").map { |link| link["href"] }.compact.first
        match = href&.match(%r{/blog/author/([^/?#]+)/?})
        match ? normalize_author_key(match[1]) : nil
      end
    rescue StandardError => e
      @logger.error("Failed to resolve blog author username for #{item.url}: #{e.class}: #{e.message}")
      nil
    end

    def already_published_url?(publisher, url)
      return publisher.already_published_url?(url) if publisher.respond_to?(:already_published_url?)

      false
    end

    def rss_items(rss_url)
      xml = URI.open(rss_url).read
      feed = RSS::Parser.parse(xml, false)

      feed.items.first(@rss_item_limit).filter_map do |item|
        url = item_link(item)&.strip
        next unless url && !url.empty?

        FeedItem.new(url: url, title: item_title(item), author_name: item_author(item), published_at: item_published_at(item))
      end.uniq { |item| item.url }
    end

    def log_skip(article, publisher, reason)
      @logger.info("Skipping republishing #{article_label(article)} to #{publisher.name} [#{reason}]")
    end

    def article_label(article)
      title = article.respond_to?(:title) ? article.title.to_s.strip : ""
      title.empty? ? article.url : title
    end

    def item_title(item)
      item.respond_to?(:title) ? item.title.to_s.strip : ""
    end

    def item_link(item)
      return item.link.href if item.respond_to?(:link) && item.link.respond_to?(:href)
      return item.link if item.respond_to?(:link) && item.link
      return item.guid.content if item.respond_to?(:guid) && item.guid.respond_to?(:content)
      return item.guid.to_s if item.respond_to?(:guid) && item.guid

      nil
    end

    def item_published_at(item)
      raw_date = if item.respond_to?(:pubDate) && item.pubDate
                   item.pubDate
                 elsif item.respond_to?(:date) && item.date
                   item.date
                 elsif item.respond_to?(:dc_date) && item.dc_date
                   item.dc_date
                 end

      return raw_date if raw_date.is_a?(Time)

      Time.parse(raw_date.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def old_enough?(item)
      return false unless item.published_at

      item.published_at <= Time.now - (@republish_after_days * 86_400)
    end

    def item_author(item)
      author = if item.respond_to?(:dc_creator) && item.dc_creator
                 item.dc_creator
               elsif item.respond_to?(:author) && item.author
                 item.author
               elsif item.respond_to?(:itunes_author) && item.itunes_author
                 item.itunes_author
               end

      author.to_s.strip
    end

    def normalize_author_key(author_name)
      author_name.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          @logger.info("Received #{signal}; stopping after current cycle")
          @stop = true
        end
      end
    end
  end
end
