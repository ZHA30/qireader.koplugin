# QiReader API OpenAPI Reference

Observed from `https://www.qireader.com` on 2026-06-13.

The API contract is maintained as an OpenAPI 3.1 document:

```text
openapi.yaml
```

Base URL:

```text
https://www.qireader.com/api
```

Use `/api/*`. Direct `/_api/*` requests return the frontend application HTML.

Common request headers:

```http
accept: application/json
content-type: application/json
x-api-version: 21.0.0
```

Authentication uses session cookies returned by `POST /session`.

Reading-related implementation notes confirmed by safe probes:

- Stream lists for categories use `category-{categoryId}`.
- The synthetic `!all` label is not itself a valid stream id; use the real category id whose label is `!all`.
- Subscription article lists are available through both `subscription-{subscriptionId}` and `feed-{feedId}` stream ids, but they do not currently agree on read status for the same entries. Plugin work should prefer `subscription-*` because it preserves subscription-scoped status.
- `GET /entry/{entryId}` returns metadata only. Full article HTML should be fetched from `GET /entry-contents`.
- `GET /entry-contents` requires both `streamId` and repeated `entryIds` query keys. Using `entryId` instead of `entryIds` returned `500` during probing.
- The reading list endpoints expose `articleOrder`, `unreadOnly`, `olderThan`, and `newerThan`. The safest pagination cursor observed so far is the opaque `timestamp` field rather than `publishedAt`.

Write-path notes confirmed by live state-changing probes on 2026-06-14:

- `PUT /markers/reads` successfully changed an entry from unread to read, and the new `status` was visible through both `GET /entry/{entryId}` and the parent `/streams/{streamId}` response.
- `PUT /markers/unread` successfully restored the same entry back to unread, and the restored `status` was visible through both metadata and stream responses.
- `!readlater` is a special tag exposed by `GET /tags`. `PUT /entries/{entryId}/tags/{tagId}` and `DELETE /entries/{entryType}/{entryId}/tags/{tagId}` both worked when the request included the JSON body fields `entryType`, `entryId`, and `tagId`.
- Read-later state is reflected by `tagIds`, not by `isSaved`. In the sampled probe, adding `!readlater` changed `tagIds` in both `GET /entry/{entryId}` and `/streams/{streamId}`, while `isSaved` remained `false`.

The OpenAPI document groups operations with these tags:

```text
Protocol
Session
Subscriptions
Categories
Tags
Feeds
Discovery
Reading
Preferences
Ebook
Feedback
```
