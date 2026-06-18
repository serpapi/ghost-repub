# ghost-repub

A Ruby tool that converts SerpApi Ghost blog posts into Markdown and republishes them to services like [DEV.to](https://dev.to).

It supports two modes:

- `cli.rb`: one-off conversion/posting for a single Ghost post URL.
- `server.rb`: long-running RSS worker that polls the main SerpApi blog feed and republishes posts when the blog author has a matching publishing token.

## Features

- Extracts post metadata like title, description, tags, cover image, publication date, and canonical URL.
- Converts Ghost post content (`section.post-full-content`) to Markdown via `reverse_markdown`.
- Handles Ghost bookmark cards, image cards, callout cards, and code block language hints.
- Can save Markdown output to `<slug>.md`.
- Can post to DEV.to as a draft or published article.
- Polls the main SerpApi blog RSS feed continuously.
- Uses blog author usernames and ENV tokens; no local database or token storage.
- Checks DEV.to drafts and published posts to avoid duplicates.
- Uses a publisher abstraction so additional services can be added later.

## Installation

```bash
bundle install
cp .env.example .env
```

Edit `.env` and add real tokens/runtime options.

## One-off CLI usage

Generate a Markdown file from a Ghost post URL:

```bash
ruby cli.rb <post-url>
```

Also create a DEV.to draft:

```bash
ruby cli.rb --devto <post-url>
```

Publish directly instead of creating a draft:

```bash
ruby cli.rb --devto --publish <post-url>
```

For one-off DEV.to posting, set this in `.env`:

```env
DEVTO_API_KEY=your_dev_api_key
```

## Long-running server

Run the standalone server/worker locally:

```bash
./server.rb
```

The standalone server runs continuously until stopped with `Ctrl+C` or `TERM`.

For Rack-based platforms like CapRover's Ruby Rack template, the app also includes `config.ru`. The Rack app starts the republishing worker in a background thread and responds to HTTP requests with a simple health message:

```text
repub rack app running
```

Use only one app instance/replica for the Rack deployment. Multiple replicas would start multiple worker threads and could race to create the same DEV.to draft/post.

The worker:

1. Fetches RSS feeds.
2. If `AUTHORS` is set, uses individual author feeds like `https://serpapi.com/blog/author/josef/rss/`.
3. If `AUTHORS` is not set, falls back to the main feed at `https://serpapi.com/blog/rss/`.
4. Resolves or uses the blog author username, e.g. `hilman`.
5. Looks for a matching author token in ENV, e.g. `HILMAN_DEVTO_TOKEN`.
6. Skips the item if no token is configured for that author.
7. Processes feed items from oldest to newest.
8. Skips the item if it is newer than `REPUBLISH_AFTER_DAYS`.
9. Checks DEV.to existing authenticated articles/drafts by `canonical_url` before posting.
10. Skips the item if the author already has a DEV.to article/draft from the last 18 hours.
11. Converts the post using the Ghost-to-Markdown extractor.
12. Publishes via each configured service using that author's token.
13. Stops processing additional posts for that author after one successful republish in the current loop. The next eligible post is handled in the next loop.

## ENV configuration

Example:

```env
AUTHORS=josef,hilman

HILMAN_DEVTO_TOKEN=hilman_devto_token
JOSEF_DEVTO_TOKEN=josef_devto_token
JORDANNE_DEVTO_TOKEN=jordanne_devto_token

REPUB_DEVTO_ORGANIZATION_ID=2993
REPUB_DEVTO_PUBLISHED=false
```

Author token names use the SerpApi blog author username from the URL:

```text
https://serpapi.com/blog/author/hilman/   -> HILMAN_DEVTO_TOKEN
https://serpapi.com/blog/author/josef/    -> JOSEF_DEVTO_TOKEN
https://serpapi.com/blog/author/jordanne/ -> JORDANNE_DEVTO_TOKEN
```

There is only one supported DEV.to author-token naming convention:

```text
<BLOG_AUTHOR_USERNAME>_DEVTO_TOKEN
```

If `AUTHORS` is set, only those individual author feeds are scanned. If it is unset or empty, the main RSS feed is scanned instead. If the matching token is not set, the RSS item is skipped before conversion/publishing.

## Server logging

On startup, both `server.rb` and `config.ru` log the current configuration without printing tokens:

```text
Repub server starting
Mode: rack background worker
RSS feed: https://serpapi.com/blog/rss/
Services: devto
Polling every 120 seconds
Checking latest 10 RSS item(s)
Republishing posts at least 3 days old
DEV.to organization ID: 2993
DEV.to mode: draft
```

Server logs use service-oriented messages such as:

```text
Republishing Amazon ASIN Lookup API: Find and Fetch Product Details to devto
Skipping republishing Amazon ASIN Lookup API: Find and Fetch Product Details to devto [already published]
Skipping republishing Amazon ASIN Lookup API: Find and Fetch Product Details to devto [missing token]
Skipping republishing Amazon ASIN Lookup API: Find and Fetch Product Details to devto [too new]
Skipping republishing Amazon ASIN Lookup API: Find and Fetch Product Details to devto [recent article]
```

## Worker behavior constants

Worker behavior is configured as constants in `repub/lib/repub/config.rb`:

```ruby
BLOG_BASE_URL = "https://serpapi.com/blog"
RSS_URL = "#{BLOG_BASE_URL}/rss/"
POLL_INTERVAL_SECONDS = 12 * 60 * 60
RSS_ITEM_LIMIT = 10
REPUBLISH_AFTER_DAYS = 3
AUTHOR_COOLDOWN_SECONDS = 18 * 60 * 60
ENABLED_SERVICES = %w[devto].freeze
```

The worker checks immediately on startup, then polls every 12 hours. Posts are only eligible for republishing after they are at least 3 days old. In each loop, posts are processed oldest-to-newest, only one successful republish per author is performed, and an author is skipped if DEV.to reports any article/draft from the last 18 hours.

## DEV.to behavior

The DEV.to publisher sends:

```json
{
  "article": {
    "published": false,
    "organization_id": 2993
  }
}
```

Set this to publish immediately:

```env
REPUB_DEVTO_PUBLISHED=true
```

The API key must be a DEV.to user API key for the matching author. If `REPUB_DEVTO_ORGANIZATION_ID` is set, that user must belong to the organization. DEV.to does not provide organization-only posting tokens via the public API.

## Duplicate handling without local storage

The worker does not save local state. To avoid duplicate DEV.to posts, it queries:

```http
GET https://dev.to/api/articles/me/all
```

using each author's token and compares existing article `canonical_url` values with the source post URL/canonical URL. This endpoint includes both published articles and drafts, so draft-mode republishing also skips posts that already have DEV.to drafts. The same endpoint is checked fresh when enforcing the 18-hour author cooldown.

This means:

- Restarts should still avoid duplicates already present on DEV.to.
- If a destination service does not support listing/checking existing posts, a future publisher will need its own remote duplicate strategy.
- In-memory `seen` state also prevents reposting the same RSS item repeatedly during a single process run.

## Adding another publishing service

Add a new class under `lib/repub/publishers/` that implements:

```ruby
name
configured?
already_published?(post)
already_published_url?(url) # optional but recommended for pre-extraction duplicate checks
publish(post)
```

Then register it in `Repub::Config.publishers_for_author_key` and add the service name to `ENABLED_SERVICES`.

## CapRover deployment

This project includes both:

- `config.ru` for Rack compatibility
- `Dockerfile` plus `captain-definition` for explicit CapRover Dockerfile builds

The checked-in `captain-definition` points CapRover at `./Dockerfile`:

```json
{
  "schemaVersion": 2,
  "dockerfilePath": "./Dockerfile"
}
```

The Dockerfile runs:

```dockerfile
CMD ["bundle", "exec", "rackup", "config.ru", "--host", "0.0.0.0", "--port", "80"]
```

Make sure your CapRover app environment variables include the author tokens and DEV.to options, for example:

```env
HILMAN_DEVTO_TOKEN=...
REPUB_DEVTO_ORGANIZATION_ID=2993
REPUB_DEVTO_PUBLISHED=false
```

The Rack process should show startup logs like:

```text
Repub server starting
Mode: rack background worker
```

If you do not see those lines, CapRover is likely not booting this repo's `config.ru`.

In the build log, a correct Dockerfile-based build should include lines like:

```text
COPY Gemfile Gemfile.lock ./
RUN bundle exec ruby -c config.ru && ...
CMD ["bundle", "exec", "rackup", "config.ru", "--host", "0.0.0.0", "--port", "80"]
```

If the build log instead shows `templateId: ruby-rack` behavior or `CMD ["rackup", ...]` without `bundle exec`, CapRover is not using the current `captain-definition`/`Dockerfile` revision.

## Platforms

### DEV.to

Supported for one-off posting and the long-running server.

### Hashnode

Not automated yet. The generated Markdown body can be pasted into the Hashnode editor. Use metadata from the frontmatter to set title, tags, and canonical URL manually.

## Contributing

Feel free to open a PR.

&copy; 2026 SerpApi
