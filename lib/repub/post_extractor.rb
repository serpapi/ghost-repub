require "open-uri"
require "nokogiri"
require "reverse_markdown"
require "time"
require "uri"

require_relative "post"

module Repub
  class PostExtractor
    def self.call(url)
      new.call(url)
    end

    def call(url)
      uri = URI.parse(url)
      slug = uri.path.chomp("/").split("/").last
      raise "Could not extract slug from URL: #{url}" if slug.nil? || slug.empty?

      html = URI.open(url).read
      doc = Nokogiri::HTML(html)

      title = (doc.at_css("h1.post-full-title") || doc.at_css("h1"))&.text&.strip || ""
      description = doc.at_css("meta[name='description']")&.[]("content") || ""
      tags = doc.css("a.post-card-tags, .post-card-primary-tag, a[href*='/tag/']")
                .map { |t| t.text.strip.downcase.gsub(/[^a-z0-9]/, "") }
                .reject(&:empty?)
                .uniq
                .first(4)
      cover_image = doc.at_css("meta[property='og:image']")&.[]("content") || ""
      raw_time = doc.at_css("time[datetime]")&.[]("datetime")
      published_at = raw_time ? Time.parse(raw_time).utc.strftime("%Y-%m-%d %H:%M %z") : ""
      canonical_url = doc.at_css("link[rel='canonical']")&.[]("href") || url
      author_key = extract_author_key(doc)

      section = doc.at_css("section.post-full-content")
      raise "No section.post-full-content found on page: #{url}" unless section

      markdown = extract_markdown(doc, section)

      Post.new(
        url: url,
        slug: slug,
        title: title,
        description: description,
        tags: tags,
        cover_image: cover_image,
        published_at: published_at,
        canonical_url: canonical_url,
        author_key: author_key,
        markdown: markdown
      )
    end

    private

    def extract_author_key(doc)
      href = doc.css("a[href*='/blog/author/']").map { |link| link["href"] }.compact.first
      match = href&.match(%r{/blog/author/([^/?#]+)/?})
      match && match[1].to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def extract_markdown(doc, section)
      bookmarks = []
      section.css(".kg-bookmark-card").each_with_index do |card, i|
        anchor = card.at_css("a")
        href = anchor&.[]("href")
        title_text = card.at_css(".kg-bookmark-title")&.text&.strip
        thumbnail = card.at_css(".kg-bookmark-thumbnail img")&.[]("src")
        bookmarks << { href: href, title: title_text, thumbnail: thumbnail }
        placeholder = doc.create_element("p")
        placeholder.add_child(doc.create_text_node("REPUBBOOKMARK#{i}"))
        card.replace(placeholder)
      end

      section.css(".kg-card").each do |card|
        images = card.css("img")
        if images.any?
          wrapper = doc.create_element("div")
          figcaption = card.at_css("figcaption")&.text&.strip
          images.each do |img|
            alt = img["alt"]&.strip
            alt = nil if alt.nil? || alt.empty? || alt.match?(/upload in progress/i)
            img["alt"] = alt || figcaption || ""
            anchor = img.ancestors("a").first
            if anchor && anchor["href"]
              link_el = doc.create_element("a", href: anchor["href"])
              link_el.add_child(img)
              wrapper.add_child(link_el)
            else
              wrapper.add_child(img)
            end
          end
          if figcaption && !figcaption.empty?
            caption_p = doc.create_element("p")
            caption_em = doc.create_element("em")
            caption_em.content = figcaption
            caption_p.add_child(caption_em)
            wrapper.add_child(caption_p)
          end
          card.replace(wrapper)
        elsif (emoji = card.at_css(".kg-callout-emoji")) && (text = card.at_css(".kg-callout-text"))
          blockquote = doc.create_element("blockquote")
          blockquote.inner_html = "#{emoji.text.strip} #{text.inner_html.strip}"
          card.replace(blockquote)
        else
          blockquote = doc.create_element("blockquote")
          card.children.each { |child| blockquote.add_child(child) }
          card.replace(blockquote)
        end
      end

      code_blocks = []
      section.css("pre").each_with_index do |pre, i|
        code = pre.at_css("code") || pre
        language = code["class"]&.scan(/(?:^|\s)language-([^\s]+)/)&.flatten&.first
        code_blocks << { code: code.text, language: language }

        placeholder = doc.create_element("p")
        placeholder.add_child(doc.create_text_node("REPUBCODEBLOCK#{i}"))
        pre.replace(placeholder)
      end

      markdown = ReverseMarkdown.convert(section.inner_html, unknown_tags: :bypass)

      markdown.gsub!(/REPUBBOOKMARK(\d+)/) do
        bookmark = bookmarks.fetch(Regexp.last_match(1).to_i)
        next "" unless bookmark[:href]

        display = present?(bookmark[:title]) ? bookmark[:title] : bookmark[:href]
        "- [#{display}](#{bookmark[:href]})"
      end

      markdown.gsub!(/REPUBCODEBLOCK(\d+)/) do
        code_block = code_blocks.fetch(Regexp.last_match(1).to_i)
        fenced_code_block(code_block[:code], code_block[:language])
      end

      markdown.gsub!(/^ +(!?\[)/, '\\1')
      markdown
    end

    def fenced_code_block(code, language)
      normalized_code = code.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      longest_backtick_run = normalized_code.scan(/`+/).map(&:length).max.to_i
      fence = "`" * [3, longest_backtick_run + 1].max
      info = language.to_s.downcase.gsub(/[^a-z0-9_+.-]/, "")
      normalized_code = "#{normalized_code}\n" unless normalized_code.end_with?("\n")

      "#{fence}#{info}\n#{normalized_code}#{fence}"
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
