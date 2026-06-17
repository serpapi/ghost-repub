require_relative "publishers/devto"

module Repub
  class Config
    RSS_URL = "https://serpapi.com/blog/rss/"
    POLL_INTERVAL_SECONDS = 3 * 60 * 60
    RSS_ITEM_LIMIT = 10
    REPUBLISH_AFTER_DAYS = 3

    ENABLED_SERVICES = %w[devto].freeze

    def self.rss_url
      RSS_URL
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

    def self.enabled_services
      ENABLED_SERVICES
    end

    def self.devto_published?
      truthy?(ENV.fetch("REPUB_DEVTO_PUBLISHED", "false"))
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
            published: devto_published?
          )
        else
          raise "Unknown service: #{service}"
        end
      end
    end

    def self.token_env_name_for_author_key(author_key)
      "#{env_author_key(author_key)}_DEVTO_TOKEN"
    end

    def self.author_devto_token(author_key)
      ENV[token_env_name_for_author_key(author_key)]
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

    private_class_method :author_devto_token, :normalize_author_key, :env_author_key, :truthy?
  end
end
