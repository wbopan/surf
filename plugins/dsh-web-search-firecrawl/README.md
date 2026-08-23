# dsh-web-search-firecrawl

A Firecrawl-backed `WebSearchProvider` **and** `WebFetchProvider` for the
DeepSeek Harness web capability seam (`ctx.web`). It registers both under the
stable id **`firecrawl`**: search calls Firecrawl's v2 `/search` endpoint, and
fetch calls the v2 `/scrape` endpoint — so one model `web_search` or `web_fetch`
call costs a handful of Firecrawl credits instead of a full DeepSeek Messages
model turn.

This is an **implementation** package: it registers providers into `ctx.web`,
resolves its credential for each operation through the optional `ctx.credentials`
seam, and does **not** register a model-facing tool. The model-facing
`web_search` / `web_fetch` contract stays owned by `@deepseek-ai/dsh-tool-web`.

## What it does

- Registers a `WebSearchProvider` (`id: "firecrawl"`) backed by `POST {baseURL}/v2/search`.
- Registers a `WebFetchProvider` (`id: "firecrawl"`) backed by `POST {baseURL}/v2/scrape`, returning Firecrawl's cleaned markdown as `WebFetchBody` `kind: "text"`.
- `POST {baseURL}/v2/search` (`Authorization: Bearer <key>`), body
  `{ query, limit, sources: ["web"] }`; maps `data.web[]` (`url` / `title` /
  `description`) into the seam's normalized `WebSearchSource` shape, deduped by URL.
- `POST {baseURL}/v2/scrape` (`Authorization: Bearer <key>`), body
  `{ url, formats: ["markdown"], onlyMainContent: true }`; maps `data`
  (`url`, `statusCode`, `markdown`) into `WebFetchResult` with
  `body: { kind: "text", content: <markdown> }`; the tool layer owns output
  truncation (`truncated` is `false` at the provider).
- Surfaces `WEB_PROVIDER_ERROR` for HTTP failures, `WEB_ABORTED` for caller
  cancellation, `WEB_PROVIDER_CREDENTIAL_MISSING` when no key resolves.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `apiKey` | omitted | Literal Firecrawl API key. Prefer `apiKeyEnv` so no secret enters configuration; a non-empty literal wins. |
| `apiKeyEnv` | `FIRECRAWL_API_KEY` | Credential reference resolved per search through `ctx.credentials` (the Web Models page manages it), or from the launching environment. A missing value fails the call as `WEB_PROVIDER_CREDENTIAL_MISSING`. |
| `baseURL` | `https://api.firecrawl.dev` | Firecrawl base; `/v2/search` (search) or `/v2/scrape` (fetch) is appended. Falls back to `$FIRECRAWL_API_URL` (self-hosted). |
| `maxResults` | `8` | Result cap sent as Firecrawl `limit`. The seam enforces `request.maxResults` regardless. |
| `timeoutMs` | `30000` | Per-search HTTP timeout budget (ms). |

```yaml
- id: web-search-firecrawl
  name: dsh-web-search-firecrawl
  config:
    apiKeyEnv: FIRECRAWL_API_KEY
    baseURL: https://api.firecrawl.dev
    maxResults: 8
```

## Install (web profile)

The web profile bundles the harness plus profile plugins. Add this package as a
linked dependency and to `dsh.profile.bundles`:

```bash
# from the web profile dir
cd ~/.dsh/profiles/web
# symlink the package into the profile's node_modules (as dsharness-web-adapter does)
ln -s /Users/wenbopan/Repos/dsh-mac/plugins/dsh-web-search-firecrawl \
  node_modules/dsh-web-search-firecrawl
```

Then append `"dsh-web-search-firecrawl"` to `package.json`'s `dsh.profile.bundles`
(which activates its `cordis.patch.yml`, inserting the `web-search-firecrawl` row).

## Point the seam at it

In the profile's `cordis.patch.yml` (a whole-entry config replace, not a merge):

```yaml
- id: web
  config:
    searchProvider: firecrawl
    fetchProvider: firecrawl
```

The built-in `web-search-deepseek` provider row stays mounted (harmless; it just
isn't selected), so switching back is a one-line revert. Restart the harness after
`web` config or provider changes.

## Credentials

Store the Firecrawl key under the reference the section names (default
`FIRECRAWL_API_KEY`) — via the Web Models page or by adding it to
`~/.dsh/.credentials.yaml`:

```yaml
version: 1
refs:
  FIRECRAWL_API_KEY: fc-your-api-key
```

The provider resolves the reference per search, so a key stored or rotated on the
Web Models page reaches the next call without a restart.

## Rollback

Set `web.searchProvider` back to `deepseek-official` in the profile
`cordis.patch.yml` (and remove the `dsh-web-search-firecrawl` bundle, if desired),
then restart.
