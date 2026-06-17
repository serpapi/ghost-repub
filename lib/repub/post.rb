module Repub
  Post = Struct.new(
    :url,
    :slug,
    :title,
    :description,
    :tags,
    :cover_image,
    :published_at,
    :canonical_url,
    :markdown,
    keyword_init: true
  ) do
    def frontmatter(published: false)
      <<~FRONT
        ---
        title: #{title}
        published: #{published}
        description: #{description}
        tags: #{tags.join(", ")}
        cover_image: #{cover_image}
        # published_at: #{published_at}
        canonical_url: #{canonical_url}
        ---
      FRONT
    end
  end
end
