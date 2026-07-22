require "json"
require "net/http"
require "set"
require "time"
require "uri"

module Repub
  module Publishers
    class Hashnode
      class PublishOutcomeUnknown < RuntimeError
        def publish_outcome_unknown?
          true
        end
      end

      API_URL = "https://gql-beta.hashnode.com/"
      PUBLISH_RECONCILIATION_ATTEMPTS = 7
      PUBLISH_RECONCILIATION_INTERVAL_SECONDS = 5

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
            username
          }
        }
      GRAPHQL

      PUBLICATION_MEMBERS_QUERY = <<~GRAPHQL
        query PublicationMembers($publicationId: ObjectId!, $after: String) {
          publication(id: $publicationId) {
            title
            members(first: 100, after: $after) {
              edges {
                node {
                  role
                  user {
                    id
                    username
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

      PUBLICATION_POSTS_QUERY = <<~GRAPHQL
        query PublicationPosts($publicationId: ObjectId!, $after: String) {
          publication(id: $publicationId) {
            posts(first: 100, after: $after) {
              edges {
                node {
                  id
                  slug
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

      def destination_key
        "hashnode:#{@publication_id}"
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
        validate_publish_access!

        payload = graphql(
          query: PUBLISH_POST_MUTATION,
          variables: { input: publish_input(post) }
        )
        hashnode_post = payload.fetch("data").fetch("publishPost").fetch("post")
        remember_published_source_urls(post)
        hashnode_post
      rescue PublishOutcomeUnknown
        hashnode_post = reconcile_published_post(post)
        raise unless hashnode_post

        remember_published_source_urls(post)
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

      def remember_published_source_urls(post)
        @published_source_urls&.add(post.canonical_url)
        @published_source_urls&.add(post.url)
      end

      def reconcile_published_post(post)
        PUBLISH_RECONCILIATION_ATTEMPTS.times do |attempt|
          hashnode_post = posts.find do |candidate|
            [post.canonical_url, post.url].include?(candidate["canonicalUrl"]) || candidate["slug"] == post.slug
          end
          return hashnode_post if hashnode_post
          break if attempt == PUBLISH_RECONCILIATION_ATTEMPTS - 1

          sleep PUBLISH_RECONCILIATION_INTERVAL_SECONDS
        end

        nil
      end

      def latest_article_at
        posts.select { |post| post.dig("author", "id") == current_author_id }
             .filter_map { |post| parse_time(post["publishedAt"]) }
             .max
      end

      def current_author_id
        current_user.fetch("id")
      end

      def current_user
        @current_user ||= graphql(query: CURRENT_USER_QUERY, variables: {}).fetch("data").fetch("me")
      end

      def validate_publish_access!
        publication, members = publication_and_members
        member = members.find { |candidate| candidate.dig("user", "id") == current_author_id }
        username = current_user.fetch("username")
        publication_name = publication.fetch("title")

        unless member
          raise "Hashnode user @#{username} is not a member of #{publication_name}; use a token for an organization member"
        end

        return unless member.fetch("role").to_s.upcase == "CONTRIBUTOR"

        raise "Hashnode user @#{username} is a CONTRIBUTOR in #{publication_name} and cannot publish directly; use an owner/editor token or change the member role"
      end

      def publication_and_members
        all_members = []
        publication = nil
        after = nil

        loop do
          payload = graphql(
            query: PUBLICATION_MEMBERS_QUERY,
            variables: { publicationId: @publication_id, after: after }
          )
          publication = payload.fetch("data").fetch("publication")
          connection = publication.fetch("members")
          all_members.concat(connection.fetch("edges").map { |edge| edge.fetch("node") })
          page_info = connection.fetch("pageInfo")
          break unless page_info.fetch("hasNextPage")

          after = page_info.fetch("endCursor")
        end

        [publication, all_members]
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
          message = hashnode_error_message(response, payload["errors"], query, variables)
          if publish_outcome_unknown?(query, payload["errors"])
            raise PublishOutcomeUnknown, "#{message}; the post may have been created, so do not retry immediately"
          end

          raise message
        end

        payload
      rescue JSON::ParserError
        raise "Hashnode API error #{response&.code}: invalid JSON response: #{response&.body}"
      end

      def publish_outcome_unknown?(query, errors)
        query.match?(/\bmutation\s+PublishPost\b/) && errors.any? do |error|
          error["path"]&.first(2) == %w[publishPost post]
        end
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
