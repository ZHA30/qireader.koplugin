# QiReader API Probe Log

## 2026-06-13 Safe Probe

Authenticated with `POST /api/session` using credentials from `.env`. Secret values were not recorded.

Verified:

| Request | Status | Result |
| --- | --- | --- |
| `GET /api/versions` without session | `401` | Protected endpoint |
| `GET /_api/versions` | `200 text/html` | Frontend HTML, not JSON API |
| `POST /api/session` | `200` | Session cookies set |
| `GET /api/session/user` | `200` | User object |
| `GET /api/versions` | `200` | `preferences`, `subscriptions`, `tags` |
| `GET /api/subscriptions` | `200` | `categories`, `subscriptionCategories`, `subscriptions`, `version` |
| `GET /api/tags` | `200` | `tags`, `version` |
| `GET /api/preferences` | `200` | Preference groups and version |
| `GET /api/markers/unread/counts` | `200` | `unreadCounts` |
| `GET /api/feed-basic-states` | `200` | `feedStates` |
| `GET /api/feeds/{id}` | `200` | Feed metadata |
| `GET /api/feed-state?id={feedId}` | `200` | Feed state |
| `GET /api/feed-tags?id={feedId}` | `200` | Feed tag statistics |
| `GET /api/search` | `200` | Feed results |
| `POST /api/opml` | `200` | Parsed OPML items |
| `GET /api/opml/featured/en` | `200` | Featured OPML items |
| `GET /api/opml/featured/zh` | `500` | `Internal Server Error` |
| `GET /api/streams/category-{id}` | `200` | Stream entries |
| `GET /api/streams/tag-{id}` | `200` | Stream entries |
| `GET /api/streams/category-!all` | `400` | Invalid id format |
| `GET /api/entry/{entryId}?streamId={streamId}` | `200` | Entry metadata |
| `GET /api/entry-contents?streamId={streamId}&entryIds={entryId}` | `200` | Entry content array |
| `GET /api/entry-contents?entryIds={entryId}` | `500` | `Internal Server Error` |

Observed session cookies:

```text
qireader_auth
qireader_auth.sig
qireader_user_id
qireader_user_id.sig
```

`GET /api/versions` returned `200` with and without `x-api-version: 21.0.0` during probing.

Skipped destructive or state-changing endpoints: user deletion, subscription/category/tag mutation, read markers, preference mutation, ebook sending, feedback sending.

## 2026-06-14 Reading Flow Probe

Authenticated with `POST /api/session` using credentials from `.env`. Secret values were not recorded.

Verified:

| Request | Status | Result |
| --- | --- | --- |
| `GET /api/streams/category-{id}?count=3&articleOrder=0` | `200` | Category stream returns entries and `hasMore` |
| `GET /api/streams/category-{allCategoryId}` | `200` | The real `!all` category id is valid as a stream id |
| `GET /api/streams/subscription-{subscriptionId}` | `200` | Subscription stream returns entries and preserves mixed read/unread status |
| `GET /api/streams/feed-{feedId}` | `200` | Feed stream returns entries but may disagree with `subscription-*` on `status` for the same entry ids |
| `GET /api/streams/...&unreadOnly=true` | `200` | Returned rows were filtered to unread (`status = 0`) |
| `GET /api/streams/...&articleOrder=0` | `200` | First page was newest-first by `timestamp` |
| `GET /api/streams/...&articleOrder=1` | `200` | First page was oldest-first by `timestamp` |
| `GET /api/streams/...&olderThan={timestamp}` | `200` | Using the last row `timestamp` advanced pagination in the same sort direction |
| `GET /api/streams/...&newerThan={timestamp}` | `200` | Returned rows newer than the supplied `timestamp` |
| `GET /api/entry/{entryId}?streamId={streamId}` | `200` | Metadata object included `author`, `thumbnail`, `attachments`, `timestamp`, `status` |
| `GET /api/entry-contents?streamId={streamId}&entryIds={id1}&entryIds={id2}` | `200` | Repeated `entryIds` keys returned multiple HTML payloads |
| `GET /api/entry-contents?streamId={streamId}&entryId={entryId}` | `500` | Singular `entryId` key is rejected |

Observed details:

- Category and subscription stream responses include `result.id`, `entries`, and `hasMore`.
- Stream rows expose both `publishedAt` and opaque `timestamp`. `timestamp` behaved as the more stable pagination cursor.
- Stream rows often include `summary`, but `entries[].content` was `null` in list responses during probing.
- `GET /api/entry-contents` returned HTML content and preserved the repeated-key request order in the observed two-entry probe.
- `GET /api/preferences` exposed reading-related global keys including `articleOrder`, `unreadOnly`, `markAsReadOnScroll`, `openInNewPage`, `entryListShowFeedIcon`, `entryListShowThumbnailOnMobile`, `entryListShowThumbnailOnDesktop`, `entryListSummaryLinesOnMobile`, and `entryListSummaryLinesOnDesktop`.

Implementation guidance derived from the probe:

- For plugin article lists, prefer `subscription-{subscriptionId}` over `feed-{feedId}` to avoid losing subscription-scoped read status.
- Treat `/streams` as the article list API and `/entry-contents` as the body API.
- Use repeated `entryIds` keys for bulk content fetches.
- Use `timestamp`-based pagination first; do not infer cursors from `publishedAt` unless the API contract is re-verified.

## 2026-06-14 Live Write Probe

Authenticated with `POST /api/session` using credentials from `docs/api/.env`. A single sampled article was modified and then restored to its original state.

Sampled state before mutation:

| Field | Value |
| --- | --- |
| `streamId` | `category-zdlLgBpbm7A3yWZ6` |
| `entryId` | `wZE1AGPMa9m5qObl` |
| Initial `status` | `0` (unread) |
| Initial `isSaved` | `false` |
| Initial `tagIds` | `[]` |
| `!readlater` tag id | `zoxGMBy0Zxq3bQYD` |

Verified:

| Request | Status | Result |
| --- | --- | --- |
| `PUT /api/markers/reads` with `{"type":"entries","entryIds":["wZE1AGPMa9m5qObl"]}` | `200` | Entry marked read |
| `GET /api/entry/wZE1AGPMa9m5qObl?streamId=category-zdlLgBpbm7A3yWZ6` | `200` | `status` became `1` |
| `GET /api/streams/category-zdlLgBpbm7A3yWZ6?...` | `200` | Same row `status` became `1` in stream list |
| `PUT /api/markers/unread` with `{"entryId":"wZE1AGPMa9m5qObl"}` | `200` | Entry restored to unread |
| `GET /api/entry/wZE1AGPMa9m5qObl?streamId=category-zdlLgBpbm7A3yWZ6` | `200` | `status` returned to `0` |
| `GET /api/streams/category-zdlLgBpbm7A3yWZ6?...` | `200` | Same row `status` returned to `0` in stream list |
| `PUT /api/entries/wZE1AGPMa9m5qObl/tags/zoxGMBy0Zxq3bQYD` without body | `500` | `Internal Server Error` |
| `DELETE /api/entries/feed/wZE1AGPMa9m5qObl/tags/zoxGMBy0Zxq3bQYD` without body | `500` | `Internal Server Error` |
| `PUT /api/entries/wZE1AGPMa9m5qObl/tags/zoxGMBy0Zxq3bQYD` with `{"entryType":"feed","entryId":"wZE1AGPMa9m5qObl","tagId":"zoxGMBy0Zxq3bQYD"}` | `200` | `!readlater` tag added |
| `GET /api/entry/wZE1AGPMa9m5qObl?streamId=category-zdlLgBpbm7A3yWZ6` | `200` | `tagIds` became `["zoxGMBy0Zxq3bQYD"]`, `isSaved` stayed `false` |
| `GET /api/streams/category-zdlLgBpbm7A3yWZ6?...` | `200` | Same row `tagIds` became `["zoxGMBy0Zxq3bQYD"]` in stream list |
| `DELETE /api/entries/feed/wZE1AGPMa9m5qObl/tags/zoxGMBy0Zxq3bQYD` with `{"entryType":"feed","entryId":"wZE1AGPMa9m5qObl","tagId":"zoxGMBy0Zxq3bQYD"}` | `200` | `!readlater` tag removed |
| `GET /api/entry/wZE1AGPMa9m5qObl?streamId=category-zdlLgBpbm7A3yWZ6` | `200` | `tagIds` returned to `[]` |
| `GET /api/streams/category-zdlLgBpbm7A3yWZ6?...` | `200` | Same row `tagIds` returned to `[]` in stream list |

Observed details:

- Read/unread marker writes are immediately reflected by both `/entry/{entryId}` and `/streams/{streamId}`.
- The sampled article was restored to its initial state after the probe: unread, `isSaved = false`, `tagIds = []`.
- The `!readlater` tag is the server-backed “read later” state.
- Tag mutation endpoints were accepted only after sending the same JSON body fields used by the web app: `entryType`, `entryId`, and `tagId`.
- `isSaved` did not reflect the sampled `!readlater` toggle. The reliable field for plugin list state is `tagIds`.
