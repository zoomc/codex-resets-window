# Codex Window

Codex Window is a native macOS menu-bar companion for Codex usage. It presents the current 5-hour and weekly usage windows, lists locally indexed Codex conversations, and can schedule a selected conversation to reopen five minutes after the 5-hour window resets.

## Privacy model

- Reads `~/.codex/auth.json` only to make an authenticated, read-only usage request to ChatGPT.
- Reads `~/.codex/session_index.jsonl` locally for conversation IDs, titles, and update times.
- Does not upload, store, display, or commit access tokens, account IDs, email addresses, conversation content, or raw API responses.
- Scheduled resume launches the local `codex resume <session-id>` command. It does not send a new prompt or transmit conversation content.

## Development

```sh
swift build
swift run CodexWindow
```

`Tests/CodexWindowTests` contains a small regression test for Xcode-based development. The installed Command Line Tools toolchain does not ship XCTest, so it is intentionally not included in the standalone SwiftPM target.

The app requires a current Codex Desktop/CLI login for usage values. If the local Codex CLI is unavailable, scheduled sessions remain queued and the app shows a local notification instead.
