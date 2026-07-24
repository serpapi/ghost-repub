require_relative "publishers/devto"
require_relative "publishers/hashnode"

module Repub
  class Config
    BLOG_BASE_URL = "https://serpapi.com/blog"
    RSS_URL = "#{BLOG_BASE_URL}/rss/"
    POLL_INTERVAL_SECONDS = 8 * 60 * 60
    RSS_ITEM_LIMIT = 10
    REPUBLISH_AFTER_DAYS = 3
    AUTHOR_COOLDOWN_SECONDS = 18 * 60 * 60
    MEDIUM_LIMIT = 2

    ENABLED_SERVICES = %w[devto hashnode].freeze

    def self.rss_url
      RSS_URL
    end

    def self.author_keys
      ENV.fetch("AUTHORS", "")
         .split(",")
         .map { |author| normalize_author_key(author) }
         .reject(&:empty?)
    end

    def self.feed_sources
      if author_keys.any?
        author_keys.map do |author_key|
          {
            rss_url: "#{BLOG_BASE_URL}/author/#{author_key}/rss/",
            author_key: author_key
          }
        end
      else
        [
          {
            rss_url: RSS_URL,
            author_key: nil
          }
        ]
      end
    end

    def self.poll_interval
      POLL_INTERVAL_SECONDS
    end

    def self.rss_item_limit
      RSS_ITEM_LIMIT
    end

    def self.republish_after_days
      REPUBLISH_AFTER_DAYS
    end

    def self.author_cooldown_seconds
      AUTHOR_COOLDOWN_SECONDS
    end

    def self.medium_limit
      MEDIUM_LIMIT
    end

    def self.enabled_services
      ENABLED_SERVICES
    end

    def self.devto_published?
      truthy?(ENV.fetch("REPUB_DEVTO_PUBLISHED", "true"))
    end

    def self.devto_organization_id
      raw = ENV.fetch("REPUB_DEVTO_ORGANIZATION_ID", "2993").strip
      raw.empty? ? nil : Integer(raw)
    end

    def self.publishers_for_author_key(author_key)
      enabled_services.filter_map do |service|
        case service
        when "devto"
          Publishers::Devto.new(
            api_key: author_devto_token(author_key),
            organization_id: devto_organization_id,
            published: devto_published?,
            author_cooldown_seconds: author_cooldown_seconds
          )
        when "hashnode"
          Publishers::Hashnode.new(
            api_key: author_hashnode_token(author_key),
            publication_id: hashnode_publication_id(author_key),
            author_cooldown_seconds: author_cooldown_seconds
          )
        else
          raise "Unknown service: #{service}"
        end
      end
    end

    def self.token_env_name_for_author_key(author_key)
      "#{env_author_key(author_key)}_DEVTO_TOKEN"
    end

    def self.hashnode_token_env_name_for_author_key(author_key)
      "HASHNODE_#{env_author_key(author_key)}_TOKEN"
    end

    def self.hashnode_publication_id_env_name_for_author_key(author_key)
      "HASHNODE_#{env_author_key(author_key)}_PUBLICATION_ID"
    end



    def self.hashnode_publication_id(author_key = nil)
      author_value = ENV[hashnode_publication_id_env_name_for_author_key(author_key)] if author_key
      return author_value if present?(author_value)

      ENV["REPUB_HASHNODE_PUBLICATION_ID"]
    end

    def self.author_devto_token(author_key)
      ENV[token_env_name_for_author_key(author_key)]
    end

    def self.author_hashnode_token(author_key)
      ENV[hashnode_token_env_name_for_author_key(author_key)]
    end



    def self.normalize_author_key(key)
      key.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def self.env_author_key(author_name)
      normalize_author_key(author_name).upcase
    end

    def self.truthy?(value)
      %w[1 true yes y on].include?(value.to_s.strip.downcase)
    end

    def self.present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    private_class_method :author_devto_token, :author_hashnode_token, :normalize_author_key,
                         :env_author_key, :truthy?, :present?
  end
end
