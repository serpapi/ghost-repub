require "json"
require "net/http"
require "set"
require "uri"

module Repub
  module Publishers
    class Devto
      API_BASE_URL = "https://dev.to/api"

      def initialize(api_key:, organization_id:, published: false)
        @api_key = api_key
        @organization_id = organization_id
        @published = published
        @known_source_urls = nil
      end

      def name
        "devto"
      end

      def configured?
        !@api_key.nil? && !@api_key.empty?
      end

      def already_published?(post)
        known_source_urls.include?(post.canonical_url) || known_source_urls.include?(post.url)
      end

      def already_published_url?(url)
        known_source_urls.include?(url)
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

        known_source_urls.add(post.canonical_url)
        known_source_urls.add(post.url)

        payload
      end

      private

      def known_source_urls
        @known_source_urls ||= begin
          urls = Set.new
          page = 1

          # /articles/me/all intentionally includes both published articles and drafts.
          # This lets draft-mode republishing skip posts that were already created as drafts.
          loop do
            response = request(:get, "/articles/me/all?page=#{page}&per_page=1000")
            articles = JSON.parse(response.body)
            break if articles.empty?

            articles.each do |article|
              urls.add(article["canonical_url"]) if article["canonical_url"] && !article["canonical_url"].empty?
              urls.add(article["url"]) if article["url"] && !article["url"].empty?
            end

            break if articles.length < 1000

            page += 1
          end

          urls
        end
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

        return response if response.is_a?(Net::HTTPSuccess)

        raise "DEV.to API error #{response.code}: #{response.body}"
      end
    end
  end
end
