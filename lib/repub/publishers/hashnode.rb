require "json"
require "net/http"
require "set"
require "time"
require "uri"

module Repub
  module Publishers
    class Hashnode
      API_URL = "https://gql-beta.hashnode.com/"

      PUBLISH_POST_MUTATION = <<~GRAPHQL
        mutation PublishPost($input: PublishPostInput!) {
          publishPost(input: $input) {
            post {
              id
              slug
              url
              title
            }
          }
        }
      GRAPHQL

      CURRENT_USER_QUERY = <<~GRAPHQL
        query CurrentUser {
          me {
            id
          }
        }
      GRAPHQL

      PUBLICATION_POSTS_QUERY = <<~GRAPHQL
        query PublicationPosts($publicationId: ObjectId!, $after: String) {
          publication(id: $publicationId) {
            posts(first: 100, after: $after) {
              edges {
                node {
                  id
                  url
                  canonicalUrl
                  publishedAt
                  author {
                    id
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
      GRAPHQL

      def initialize(api_key:, publication_id:, author_cooldown_seconds: 18 * 60 * 60)
        @api_key = api_key
        @publication_id = publication_id
        @author_cooldown_seconds = author_cooldown_seconds
        @published_source_urls = nil
      end

      def name
        "hashnode"
      end

      def configured?
        present?(@api_key) && present?(@publication_id)
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
        payload = graphql(
          query: PUBLISH_POST_MUTATION,
          variables: { input: publish_input(post) }
        )
        hashnode_post = payload.fetch("data").fetch("publishPost").fetch("post")

        @published_source_urls&.add(post.canonical_url)
        @published_source_urls&.add(post.url)

        hashnode_post
      end

      private

      def publish_input(post)
        {
          publicationId: @publication_id,
          title: post.title,
          contentMarkdown: post.markdown,
          slug: post.slug,
          tags: hashnode_tags(post.tags),
          enableToc: true
        }.tap do |input|
          input[:subtitle] = post.description if present?(post.description)
          input[:metaDescription] = post.description if present?(post.description)
          input[:coverImage] = post.cover_image if present?(post.cover_image)
          input[:ogImage] = post.cover_image if present?(post.cover_image)
          input[:originalArticleURL] = canonical_url(post) if present?(canonical_url(post))
        end
      end

      def hashnode_tags(tags)
        tags.first(15).filter_map do |tag|
          slug = tag.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
          next if slug.empty?

          { slug: slug, name: tag.to_s.strip }
        end
      end

      def canonical_url(post)
        return post.canonical_url if present?(post.canonical_url)

        post.url
      end

      def published_source_urls
        @published_source_urls ||= posts.each_with_object(Set.new) do |post, urls|
          urls.add(post["canonicalUrl"]) if present?(post["canonicalUrl"])
          urls.add(post["url"]) if present?(post["url"])
        end
      end

      def latest_article_at
        posts.select { |post| post.dig("author", "id") == current_author_id }
             .filter_map { |post| parse_time(post["publishedAt"]) }
             .max
      end

      def current_author_id
        @current_author_id ||= graphql(query: CURRENT_USER_QUERY, variables: {}).fetch("data").fetch("me").fetch("id")
      end

      def parse_time(timestamp)
        Time.parse(timestamp.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def posts
        all_posts = []
        after = nil

        loop do
          payload = graphql(
            query: PUBLICATION_POSTS_QUERY,
            variables: { publicationId: @publication_id, after: after }
          )
          connection = payload.fetch("data").fetch("publication").fetch("posts")
          all_posts.concat(connection.fetch("edges").map { |edge| edge.fetch("node") })
          page_info = connection.fetch("pageInfo")
          break unless page_info.fetch("hasNextPage")

          after = page_info.fetch("endCursor")
        end

        all_posts
      end

      def graphql(query:, variables:)
        uri = URI(API_URL)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(query: query, variables: variables)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        if response.is_a?(Net::HTTPRedirection)
          destination = response["location"] || "an unknown location"
          raise "Hashnode GraphQL endpoint redirected to #{destination}; refusing to forward credentials"
        end

        payload = JSON.parse(response.body)
        raise "Hashnode API error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
        if payload["errors"] && !payload["errors"].empty?
          raise hashnode_error_message(response, payload["errors"], query, variables)
        end

        payload
      rescue JSON::ParserError
        raise "Hashnode API error #{response&.code}: invalid JSON response: #{response&.body}"
      end

      def hashnode_error_message(response, errors, query, variables)
        details = errors.map do |error|
          metadata = []
          metadata << "code=#{error.dig("extensions", "code")}" if present?(error.dig("extensions", "code"))
          metadata << "path=#{error["path"].join(".")}" if error["path"]&.any?
          if error["locations"]&.any?
            locations = error["locations"].map { |location| "#{location["line"]}:#{location["column"]}" }
            metadata << "locations=#{locations.join(",")}"
          end

          extra_extensions = error.fetch("extensions", {}).reject { |key, _value| key == "code" || key == "stacktrace" }
          metadata << "extensions=#{JSON.generate(extra_extensions)}" unless extra_extensions.empty?
          metadata.empty? ? error["message"] : "#{error["message"]} [#{metadata.join(", ")}]"
        end.join("; ")

        trace = %w[x-request-id request-id x-correlation-id traceparent cf-ray].filter_map do |header|
          value = response[header]
          "#{header}=#{value}" if present?(value)
        end

        context = hashnode_request_context(query, variables)
        suffix = ["HTTP #{response.code}", *trace, "request=#{JSON.generate(context)}"].join(", ")
        "Hashnode API error: #{details} (#{suffix})"
      end

      def hashnode_request_context(query, variables)
        operation = query.match(/\b(?:query|mutation)\s+(\w+)/)&.[](1) || "anonymous"
        input = variables[:input] || variables["input"]
        return { operation: operation, variable_keys: variables.keys.map(&:to_s).sort } unless input

        {
          operation: operation,
          publication_id: input[:publicationId] || input["publicationId"],
          slug: input[:slug] || input["slug"],
          input_fields: input.keys.map(&:to_s).sort,
          tag_slugs: Array(input[:tags] || input["tags"]).map { |tag| tag[:slug] || tag["slug"] },
          content_markdown_bytes: (input[:contentMarkdown] || input["contentMarkdown"]).to_s.bytesize
        }
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end
    end
  end
end
