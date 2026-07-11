# Codex Resets Window

Codex Resets Window is a native macOS menu-bar companion for Codex usage. It presents the current 5-hour and weekly usage windows, lists locally indexed Codex conversations, opens a selected session when its title is clicked, and can send the English `continue` prompt five minutes after the 5-hour window resets.

## Privacy model

- Reads `~/.codex/auth.json` only to make an authenticated, read-only usage request to ChatGPT.
- Reads `~/.codex/session_index.jsonl` locally for conversation IDs, dynamic titles, and update times.
- Does not upload, store, display, or commit access tokens, account IDs, email addresses, conversation content, or raw API responses.
- Clicking a title opens `<ChatGPT.app>/Contents/Resources/codex resume <session-id>` in Terminal (falling back to `codex` on PATH).
- Scheduled resume reads only the matching local session metadata to recover its original working directory, then invokes the bundled CLI as `codex -C <original-cwd> exec resume <session-id> "continue"`. This preserves the repository context while sending the selected session a new English continuation prompt.
- Every scheduled child process is retained and observed while the menu-bar app is running. Its local stdout/stderr updates the session's compact status line; normal completion or a non-zero exit is displayed and notified. Only the most recent 120-character output line stays in memory and it is never uploaded or written to the repository.
- Clicking a title opens the matching Codex Desktop task with the local `codex://threads/<session-id>` URL scheme.
- An enabled switch is a persisted, one-time continuation record. It keeps its original target time through app restarts, is retained for at most seven hours, and is removed only when the task completes, the user disables it, or it expires. This prevents stale resets from sending duplicate prompts while preserving a queued/running task after a quit or abnormal restart.
- While a selected continuation is starting or running, the app checks only that session's local transcript every 20 seconds for the paired `task_started` / `task_complete` events. This reconciles a task after an app restart without polling the network or reading unselected conversations.
- The installed app is managed by the user-level `com.codexresets.window` LaunchAgent. It starts at login and restarts only after abnormal exit; the app's explicit Quit action exits successfully and is not restarted.
- Refreshes are serialized, so launch, popover-open, and manual refresh cannot overlap usage or session-index reads.
- A persisted queued continuation schedules from its stored target time after the local session index loads, even if a transient usage-network refresh fails.
- Session metadata is read as a complete first JSONL record (up to 1 MiB), rather than a fixed prefix, because Desktop-originated session metadata can exceed 16 KiB. This restores the recorded `cwd` reliably. When the directory is valid, the CLI runs with `-C <cwd>`; when it is unavailable or is no longer a Git worktree, the app uses the CLI's explicit `--skip-git-repo-check` fallback from the user home directory instead of failing a trusted-directory preflight.
- The top-bar countdown uses a lightweight SwiftUI `TimelineView`; it does not poll the network. Network refresh happens when the popover appears or the refresh button is clicked.
- `Resources/AppIcon.svg` is the editable source for the bundled `.icns` app icon.
- Usage cards use brighter pastel accents, while session switches remain compact; enabling a switch shows the scheduled `Start at HH:MM` line beneath it.
- The 5-hour card shows a clock time while the Weekly card shows a calendar date; progress bars use explicit pastel fills rather than the system gray style.

## Development

```sh
swift build
swift run CodexResetsWindow
```

`Tests/CodexResetsWindowTests` contains a small regression test for Xcode-based development. The installed Command Line Tools toolchain does not ship XCTest, so it is intentionally not included in the standalone SwiftPM target.

The app requires a current Codex Desktop/CLI login for usage values. If the local Codex CLI is unavailable, scheduled sessions remain queued and the app shows a local notification instead.

## Continuation verification

On 2026-07-11, the exact CLI continuation path was verified against a Codex Desktop-originated local session. The command restored the selected task, accepted the English `continue` prompt, and resumed work in its original repository. No Accessibility, automation, or screen-control permission was required: the app launches the locally installed Codex CLI as a normal child process.
