# QiReader for KOReader

<img src="https://www.qireader.com/static/icon.svg" alt="QiReader icon" width="56" />

Read your QiReader subscriptions from KOReader with synced article lists, article detail reading, read-state updates, read-later actions, tags, and full-text fetching.

> [!NOTE]
> This plugin needs a QiReader account and network access.

## What it does

- Opens your QiReader subscriptions inside KOReader.
- Reads article summaries, article detail pages, and fetched full text.
- Syncs read / unread state, read-later state, and tags.
- Reopens cached content faster.

## Installation

1. Place the plugin directory under KOReader's `plugins/` directory:
   `plugins/qireader.koplugin`
2. Restart KOReader.

## How to access it

- File browser: `Search` -> `QiReader`

## Basic usage

- Log in with your QiReader account from the plugin settings menu.
- Open a subscription or tag to enter the article list.
- Tap an article title to open the article detail page.
- Use article actions for read state, read later, tags, and full text.

```text
┌────────────────────────────────────────┐
│ ☰  Subscriptions                      │
├────────────────────────────────────────┤
│ All                                   │
│ Technology                            │
│ Design                                │
│ Read Later                            │
│ Tags                                  │
└────────────────────────────────────────┘
```

```text
┌────────────────────────────────────────┐
│ ☰  Technology                    ✕    │
├────────────────────────────────────────┤
│ ● Article title                        │
│   06-15 | Feed name                    │
│                                        │
│ ○ Another article                      │
│   06-15 | Feed name                    │
│                                        │
│ ○ Third article                        │
│   06-14 | Feed name                    │
├────────────────────────────────────────┤
│ [↩] [|<] [<] [Page 1 of 8] [>]       │
└────────────────────────────────────────┘
```

```text
┌────────────────────────────────────────┐
│ ☰  Article title                 ✕    │
├────────────────────────────────────────┤
│ Summary / article content              │
│ ...                                    │
│ ...                                    │
│ ...                                    │
├────────────────────────────────────────┤
│ [<] [Fulltext] [Tags] [Read later]     │
│ [>] [Close]                            │
└────────────────────────────────────────┘
```

## Limits / Notes

- Network access is required for login, sync, and full-text fetching.
- Full-text availability depends on the source page and upstream extraction service.

## Credits / Upstream

- Official website: <https://www.qireader.com>
- Official repository: <https://github.com/oxyry/qireader>
