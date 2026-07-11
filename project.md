# Codex Resets Window

Codex Resets Window is a native macOS menu-bar companion for Codex usage. It presents the current 5-hour and weekly usage windows, lists locally indexed Codex conversations, opens a selected session when its title is clicked, and can send the English `continue` prompt five minutes after the 5-hour window resets.

## Privacy model

- Reads `~/.codex/auth.json` only to make an authenticated, read-only usage request to ChatGPT.
- Reads `~/.codex/session_index.jsonl` locally for conversation IDs, dynamic titles, and update times.
- Does not upload, store, display, or commit access tokens, account IDs, email addresses, conversation content, or raw API responses.
- Clicking a title opens `<ChatGPT.app>/Contents/Resources/codex resume <session-id>` in Terminal (falling back to `codex` on PATH).
- Scheduled resume invokes the same executable with `exec resume <session-id> "continue"` so the selected session receives a new English continuation prompt.
- The top-bar countdown uses a lightweight SwiftUI `TimelineView`; it does not poll the network. Network refresh happens when the popover appears or the refresh button is clicked.
- `Resources/AppIcon.svg` is the editable source for the bundled `.icns` app icon.
- Usage cards use brighter pastel accents, while session switches remain compact; enabling a switch shows the scheduled `Start at HH:MM` line beneath it.

## Development

```sh
swift build
swift run CodexResetsWindow
```

`Tests/CodexResetsWindowTests` contains a small regression test for Xcode-based development. The installed Command Line Tools toolchain does not ship XCTest, so it is intentionally not included in the standalone SwiftPM target.

The app requires a current Codex Desktop/CLI login for usage values. If the local Codex CLI is unavailable, scheduled sessions remain queued and the app shows a local notification instead.
