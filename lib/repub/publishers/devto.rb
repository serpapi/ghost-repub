require "json"
require "net/http"
require "set"
require "time"
require "uri"

module Repub
  module Publishers
    class Devto
      API_BASE_URL = "https://dev.to/api"
      REQUEST_INTERVAL_SECONDS = 5

      def initialize(api_key:, organization_id:, published: false, author_cooldown_seconds: 18 * 60 * 60)
        @api_key = api_key
        @organization_id = organization_id
        @published = published
        @author_cooldown_seconds = author_cooldown_seconds
        @published_source_urls = nil
      end

      def name
        "devto"
      end

      def configured?
        !@api_key.nil? && !@api_key.empty?
      end

      def destination_key
        "devto:organization:#{@organization_id}" if @organization_id
      end

      def already_published?(post)
        published_source_urls.include?(post.canonical_url) || published_source_urls.include?(post.url)
      end

      def already_published_url?(url)
        published_source_urls.include?(url)
      end

      def recent_article?
        latest_article_at&.then { |timestamp| timestamp > Time.now - @author_cooldown_seconds } || false
      end

      def publish(post)
        article = {
          title: post.title,
          body_markdown: post.markdown,
          published: @published
        }
        article[:description] = post.description unless post.description.empty?
        article[:tags] = post.tags.join(", ") unless post.tags.empty?
        article[:canonical_url] = post.canonical_url unless post.canonical_url.empty?
        article[:main_image] = post.cover_image unless post.cover_image.empty?
        article[:organization_id] = @organization_id if @organization_id

        response = request(:post, "/articles", body: { article: article })
        payload = JSON.parse(response.body)

        @published_source_urls&.add(post.canonical_url)
        @published_source_urls&.add(post.url)

        payload
      end

      private

      def published_source_urls
        @published_source_urls ||= begin
          urls = Set.new

          destination_articles.each do |article|
            urls.add(article["canonical_url"]) if article["canonical_url"] && !article["canonical_url"].empty?
            urls.add(article["url"]) if article["url"] && !article["url"].empty?
          end

          urls
        end
      end

      def destination_articles
        @organization_id ? organization_articles : articles
      end

      def latest_article_at
        articles.filter_map { |article| article_timestamp(article) }.max
      end

      def article_timestamp(article)
        raw_timestamp = article["published_at"] || article["published_timestamp"] || article["created_at"]
        Time.parse(raw_timestamp.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def organization_articles
        return [] unless @organization_id

        all_articles = []
        page = 1

        loop do
          response = request(:get, "/organizations/#{@organization_id}/articles?page=#{page}&per_page=1000")
          page_articles = JSON.parse(response.body)
          break if page_articles.empty?

          all_articles.concat(page_articles)
          break if page_articles.length < 1000

          page += 1
        end

        all_articles
      end

      def articles
        all_articles = []
        page = 1

        # /articles/me/all intentionally includes both published articles and drafts.
        # This lets draft-mode republishing skip posts that were already created as drafts,
        # and makes the author cooldown consider recently-created drafts too.
        loop do
          response = request(:get, "/articles/me/all?page=#{page}&per_page=1000")
          page_articles = JSON.parse(response.body)
          break if page_articles.empty?

          all_articles.concat(page_articles)
          break if page_articles.length < 1000

          page += 1
        end

        all_articles
      end

      def request(method, path, body: nil)
        uri = URI("#{API_BASE_URL}#{path}")
        request = case method
                  when :get
                    Net::HTTP::Get.new(uri)
                  when :post
                    Net::HTTP::Post.new(uri)
                  else
                    raise ArgumentError, "Unsupported DEV.to HTTP method: #{method}"
                  end

        request["api-key"] = @api_key
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body) if body

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        sleep REQUEST_INTERVAL_SECONDS

        return response if response.is_a?(Net::HTTPSuccess)

        raise "DEV.to API error #{response.code}: #{response.body}"
      end
    end
  end
end
