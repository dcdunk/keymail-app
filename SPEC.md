# Spotless: personal macOS mail client (Superhuman-style), Gmail only

## What Superhuman does (source: superhuman.com/mail, help.superhuman.com)
| Feature | How it works | v1? |
|---|---|---|
| Cmd+K command palette | Type any action; each row shows its single-key shortcut | Yes |
| Keyboard-first nav | j/k next/prev email, h/l next/prev split, / search, c compose, e done, r/a reply/reply-all, Enter open, Esc back | Yes |
| Split Inbox | Tabs across the top (Important, Other, VIP, Team, Calendar, custom). Custom split = rule on sender, domain, recipient, subject or label. Only shows inbox mail not marked Done | Yes |
| Mark Done | Archive. Inbox zero is the goal | Yes |
| Snooze | Hide until a time, then return to top of inbox | Yes |
| Send Later | Schedule a send | Yes |
| Follow-up reminder | On send, pick "remind me in N days if no reply" | Yes |
| Snippets | Saved text blocks with variables, recipients, attachments | Yes |
| Instant / AI reply, AI drafting | LLM drafts in your voice | v2 (local `claude` CLI on your subscription) |
| Calendar preview, email-to-event | Shows your day when a date is mentioned; creates events | v2 (Google Calendar API) |
| Read statuses | Tracking pixel; tells you who opened and on what device | Skip: needs a hosted server, and Apple Mail Privacy Protection makes it unreliable |
| Live view sharing, teammate reply indicators | Team features | Skip: single user |
| Social insights, unsubscribe tool | Sender sidebar; one-key unsubscribe via List-Unsubscribe header | Unsubscribe in v1, insights skip |

## Architecture
- **App:** native SwiftUI, macOS 14+. One window: split tabs, message list, thread view, compose sheet, Cmd+K overlay.
- **Data:** Gmail REST API, not IMAP. Labels map 1:1 to Superhuman concepts:
  - Done = remove `INBOX` label
  - Snooze = remove `INBOX`, add `Spotless/Snoozed`, store wake time locally; re-add `INBOX` at wake time
  - Splits = local rules evaluated over cached inbox messages
- **Sync:** first load `messages.list` (inbox, last 30 days), then incremental via `users.history.list` with the saved `historyId` every ~30s. Push (Pub/Sub watch) skipped: requires a Google Cloud topic and a public endpoint.
- **Cache:** SQLite (GRDB) for instant UI. Speed is the product; every keypress must hit local data, then sync in background (optimistic updates).
- **Accounts:** every email account connects through Google OAuth ("Sign in with Google" in the browser via ASWebAuthenticationSession, PKCE, no passwords ever touch the app). Refresh tokens live in the macOS Keychain. "Add account" repeats the flow; any number of Google accounts.
- **AI:** no Claude API key. The app runs the `claude` command-line tool already signed in on this Mac in headless mode (`claude -p "<prompt>" --output-format json`), so it bills to your Claude subscription. Email text is passed via stdin. If `claude` isn't found or isn't signed in, AI buttons show "Sign in to Claude Code" instead of failing silently. Uses: draft reply, summarize thread, auto-sort into splits.

## Gotchas to know before building
1. **Google OAuth scopes:** reading mail (`gmail.modify`) is a "restricted" scope. Public apps need a paid security audit. For personal use, keep the Google Cloud OAuth app in **Testing** mode and add yourself as a test user. Catch: in Testing mode refresh tokens expire after 7 days, so you re-sign-in weekly. If your accounts are on Google Workspace you control, set the app to **Internal** and that limit goes away.
2. **Send Later and snooze run locally**, so they only fire while the Mac is awake and the app (or a login-item helper) is running. Server-side scheduling would need a backend. Gmail's own native scheduled send isn't exposed in the API.
3. **Follow-up reminders:** on send, record thread ID + due date; when due, check whether the thread got a reply from someone else; if not, put it back in the inbox.

## Build order (each step shippable and testable)
1. OAuth sign-in, list inbox, open a thread (read-only)
2. Local cache + keyboard nav (j/k/Enter/Esc) + Done
3. Compose, reply, reply-all, forward
4. Cmd+K palette
5. Split Inbox rules
6. Snooze, Send Later, follow-up reminders
7. Snippets, unsubscribe, search
8. v2: AI drafting, calendar

Tests: unit tests for split rules, snooze/follow-up timing, and MIME building for sends; run on every change.

## Sources
- https://superhuman.com/mail
- https://help.superhuman.com/article/478-superhuman-command
- https://help.superhuman.com/article/441-splits
- https://help.superhuman.com/article/586-split-inboxes-2-0
- https://blakecrosley.com/es/guides/design/superhuman (unofficial shortcut list, j/k/h/l)
- Gmail API & OAuth restricted scopes / Testing-mode 7-day token expiry: Google developer docs (developers.google.com/gmail/api, support.google.com/cloud/answer/10311615), from my knowledge, not fetched this session
