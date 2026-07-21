# ghost-repub

A Ruby tool that converts SerpApi Ghost blog posts into Markdown and republishes them to services like [DEV.to](https://dev.to) and [Hashnode](https://hashnode.com).

It supports two modes:

- `cli.rb`: one-off conversion/posting for a single Ghost post URL.
- `server.rb`: long-running RSS worker that polls the main SerpApi blog feed and republishes posts when the blog author has a matching publishing token.

## Features

- Extracts post metadata like title, description, tags, cover image, publication date, and canonical URL.
- Converts Ghost post content (`section.post-full-content`) to Markdown via `reverse_markdown`.
- Handles Ghost bookmark cards, image cards, callout cards, and code block language hints.
- Can save Markdown output to `<slug>.md`.
- Can post to DEV.to as a draft or published article.
- Can publish directly to Hashnode.
- Polls the main SerpApi blog RSS feed continuously.
- Uses blog author usernames and ENV tokens; no local database or token storage.
- Checks existing DEV.to and Hashnode posts to avoid duplicates.
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

Publish directly to Hashnode:

```bash
ruby cli.rb --hashnode <post-url>
```

The CLI uses `HASHNODE_API_KEY`, matching the generic `DEVTO_API_KEY` used by the DEV.to CLI path. It always creates a new Hashnode post and does not apply the server worker's age, duplicate, or cooldown checks.

For one-off posting, set the relevant credentials in `.env`:

```env
DEVTO_API_KEY=your_dev_api_key

HASHNODE_API_KEY=your_hashnode_personal_access_token
HASHNODE_PUBLICATION_ID=your_hashnode_publication_id
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

Use only one app instance/replica for the Rack deployment. Multiple replicas would start multiple worker threads and could race to create the same destination post.

The worker:

1. Fetches RSS feeds.
2. If `AUTHORS` is set, uses individual author feeds like `https://serpapi.com/blog/author/josef/rss/`.
3. If `AUTHORS` is not set, falls back to the main feed at `https://serpapi.com/blog/rss/`.
4. Resolves or uses the blog author username, e.g. `hilman`.
5. Looks for matching author service tokens in ENV, e.g. `HILMAN_DEVTO_TOKEN` and `HASHNODE_HILMAN_TOKEN`.
6. Skips a service if its required token or publication ID is not configured for that author.
7. Processes feed items from oldest to newest.
8. Skips the item if it is newer than `REPUBLISH_AFTER_DAYS`.
9. Checks existing destination posts by canonical URL before posting.
10. Skips a service if it reports a post from the same author within the last 18 hours.
11. Converts the post using the Ghost-to-Markdown extractor.
12. Publishes via each configured service using that author's credentials.
13. Stops processing additional posts for that author after one successful republish in the current loop. The next eligible post is handled in the next loop.

## ENV configuration

Example:

```env
AUTHORS=josef,hilman

HILMAN_DEVTO_TOKEN=hilman_devto_token
JOSEF_DEVTO_TOKEN=josef_devto_token
JORDANNE_DEVTO_TOKEN=jordanne_devto_token

HASHNODE_HILMAN_TOKEN=hilman_hashnode_personal_access_token
HASHNODE_HILMAN_PUBLICATION_ID=hilman_hashnode_publication_id

# Used when an author-specific Hashnode publication ID is not set:
REPUB_HASHNODE_PUBLICATION_ID=shared_hashnode_publication_id

REPUB_DEVTO_ORGANIZATION_ID=2993
REPUB_DEVTO_PUBLISHED=true
```

Author token names use the SerpApi blog author username from the URL:

```text
https://serpapi.com/blog/author/hilman/   -> HILMAN_DEVTO_TOKEN
https://serpapi.com/blog/author/josef/    -> JOSEF_DEVTO_TOKEN
https://serpapi.com/blog/author/jordanne/ -> JORDANNE_DEVTO_TOKEN
```

Author-specific service configuration uses these naming conventions:

```text
<BLOG_AUTHOR_USERNAME>_DEVTO_TOKEN
HASHNODE_<BLOG_AUTHOR_USERNAME>_TOKEN
HASHNODE_<BLOG_AUTHOR_USERNAME>_PUBLICATION_ID
```

`REPUB_HASHNODE_PUBLICATION_ID` provides a shared fallback when an author-specific Hashnode publication ID is not set.

If `AUTHORS` is set, only those individual author feeds are scanned. If it is unset or empty, the main RSS feed is scanned instead. If the matching token is not set, the RSS item is skipped before conversion/publishing.

## Server logging

On startup, both `server.rb` and `config.ru` log the current configuration without printing tokens:

```text
Repub server starting
Mode: rack background worker
RSS feed: https://serpapi.com/blog/rss/
Services: devto, hashnode
Polling every 28800 seconds
Checking latest 10 RSS item(s)
Republishing posts at least 3 days old
DEV.to organization ID: 2993
DEV.to mode: publish
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
POLL_INTERVAL_SECONDS = 8 * 60 * 60
RSS_ITEM_LIMIT = 10
REPUBLISH_AFTER_DAYS = 3
AUTHOR_COOLDOWN_SECONDS = 18 * 60 * 60
ENABLED_SERVICES = %w[devto hashnode].freeze
```

The worker checks immediately on startup, then polls every 8 hours. Posts are eligible for republishing after they are at least 3 days old. In each loop, posts are processed oldest-to-newest, only one successful republish per author is performed, and each destination applies an 18-hour author cooldown.

## DEV.to behavior

The DEV.to publisher sends:

```json
{
  "article": {
    "published": true,
    "organization_id": 2993
  }
}
```

Direct publishing is the default. Set this to create drafts instead:

```env
REPUB_DEVTO_PUBLISHED=false
```

The API key must be a DEV.to user API key for the matching author. If `REPUB_DEVTO_ORGANIZATION_ID` is set, that user must belong to the organization. DEV.to does not provide organization-only posting tokens via the public API.

## Duplicate handling without local storage

The worker does not save local state. It queries DEV.to's `GET /api/articles/me/all` endpoint and Hashnode's paginated publication posts GraphQL connection, then compares each destination article's canonical URL with the source post URL/canonical URL. DEV.to's endpoint includes both published articles and drafts; Hashnode's query covers published posts.

Already-published source URLs are cached in memory per author/service to avoid repeating remote duplicate checks. The 18-hour cooldown checks each destination fresh.

This means:

- Restarts should still avoid duplicates already present on DEV.to or Hashnode.
- If another destination service does not support listing/checking existing posts, it will need its own remote duplicate strategy.
- The only long-lived local memory is the per-author/service cache of already-published source URLs.

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

## Hashnode behavior

The Hashnode publisher sends `publishPost` to `https://gql-beta.hashnode.com/` with the source post's Markdown, slug, tags, cover image, description, and canonical URL. The endpoint is intentionally fixed to Hashnode's documented production GraphQL host, and redirects are rejected so credentials are never forwarded to a redirect target. Hashnode API writes and publication-scoped reads require a Hashnode Pro publication.

The server queries the publication's posts and compares their `canonicalUrl` values with the source URL before publishing. It also applies the same author cooldown used for DEV.to. The manual `--hashnode` CLI path intentionally skips those checks and always attempts to create a new post.

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

Make sure your CapRover app environment variables include the author service credentials, for example:

```env
HILMAN_DEVTO_TOKEN=...
REPUB_DEVTO_ORGANIZATION_ID=2993
REPUB_DEVTO_PUBLISHED=true

HASHNODE_HILMAN_TOKEN=...
HASHNODE_HILMAN_PUBLICATION_ID=...
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

Supported for one-off force-create posting and automatic long-running server republishing. Hashnode API access requires the destination publication to have an active Pro plan.

## Contributing

Feel free to open a PR.

&copy; 2026 SerpApi
