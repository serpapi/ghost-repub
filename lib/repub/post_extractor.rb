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
        markdown: markdown
      )
    end

    private

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

      section.css("pre code").each do |code|
        lang = code["class"]&.scan(/language-(\S+)/)&.flatten&.first
        code.prepend_child(doc.create_text_node("LANG:#{lang}\n")) if lang
      end

      markdown = ReverseMarkdown.convert(section.inner_html, unknown_tags: :bypass)

      bookmarks.each_with_index do |bm, i|
        next unless bm[:href]

        display = (bm[:title] && !bm[:title].empty?) ? bm[:title] : bm[:href]
        markdown.gsub!("REPUBBOOKMARK#{i}", "- [#{display}](#{bm[:href]})")
      end

      markdown.gsub!(/^ +(!?\[)/, '\\1')
      markdown.gsub!(/^    LANG:(\S+)\n((?:^    .*\n)*)/) do
        lang = Regexp.last_match(1).downcase
        code = Regexp.last_match(2).gsub(/^    /, "")
        "```#{lang}\n#{code}```\n"
      end

      markdown
    end
  end
end
