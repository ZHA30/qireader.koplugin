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
| `GET /api/streams/feed-{id}` | `200` | Stream entries |
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
