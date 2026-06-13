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
