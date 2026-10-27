---
name: native-slack
description: Read Slack through Maki's native read-only connector, including search, channels, DMs, and complete message threads. Use for Slack links, mentions, and conversations. Never fall back to a Claude subprocess.
---

# Native Slack

Use the native `slack__*` tools. The connector exposes only read operations. It uses the user's signed-in Slack desktop session, stored in macOS Keychain. Never read, print, export, or ask the user to paste those credentials.

If tools are unavailable, ask the user to check `/mcp` and restart Maki after configuration changes. If authentication expired, the operator runs `maki-slack auth` to list workspaces, then `maki-slack auth --team WORKSPACE_ID` to refresh the selected session. Do not run authentication automatically.

## Tools

| Tool | Arguments |
|---|---|
| `slack__users_search` | `query` with an email, handle, or user ID; numeric `limit` |
| `slack__channels_list` | `channel_types`; optional numeric `limit` and `cursor` |
| `slack__channels_me` | Optional `channel_types`, numeric `limit`, and `cursor` |
| `slack__conversations_search_messages` | `search_query`; optional numeric `limit` and `cursor` |
| `slack__conversations_history` | `channel_id`; optional string `limit` or `cursor` |
| `slack__conversations_replies` | `channel_id`, `thread_ts`; optional string `limit` or `cursor` |
| `slack__conversations_unreads` | Optional `include_messages`, `mentions_only`, and numeric `max_channels` |
| `slack__usergroups_list` | Optional `include_users`, `include_count`, and `include_disabled` |

Inspect the actual tool schema before calling. Do not pass hosted-connector arguments such as `response_format`, `include_context`, `sort`, or `sort_dir`. Do not launch Claude or substitute archived messages for live reads.

## Search and threads

- Resolve the user's identity with `users_search` using their configured email or handle. Never hardcode an account or confuse a search result with the authenticated identity.
- Use Slack query syntax for mentions, dates, and conversation filters, such as `<@USER_ID> after:YYYY-MM-DD`, `to:me`, or `in:channel-name`.
- Parse responses as CSV, including quoted multiline message text. Use returned `MsgID`, `ThreadTs`, `UserID`, `Time`, `Permalink`, and `Cursor` fields rather than splitting lines or reconstructing links.
- For a Slack permalink, use its channel and root `thread_ts` when supplied. Otherwise derive the message timestamp from its `p` value and read that thread. Prefer returned `ThreadTs` for search hits; use `MsgID` for a root without `ThreadTs`.
- Follow every nonempty `Cursor`. Omit `limit` on history/thread requests that supply a cursor. A numeric message limit is a string, for example `"100"`; a time-window default is not proof of a complete thread.
- Read every page before classifying a thread as awaiting a reply or resolved. Judge its final message, not a matched message from the middle.
- Keep returned permalinks intact, including query parameters. Do not report partial or empty results as proof that an inaccessible conversation has no messages.

Access is limited to the user's own Slack permissions and retention. Files and attachment contents are not exposed by this connector. Report that limitation rather than attempting an unapproved download or adding write tools.
