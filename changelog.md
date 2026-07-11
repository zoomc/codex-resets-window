# Changelog

## 0.1.0 — 2026-07-11

- Initial native macOS menu-bar application.
- Read-only 5-hour and weekly Codex usage display.
- Local Codex conversation index and per-conversation resume scheduling.
- Privacy-first documentation and Git hygiene.
- English-first popover UI with muted usage cards and compact session rows.
- ChatGPT-style hexagonal mark combined with a live countdown ring.
- Refresh-on-open behavior, title-to-session launching, and per-session continuation scheduling.
- Scheduled `codex exec resume <session-id> "continue"` execution five minutes after reset.
- Prefer the working Codex CLI bundled inside ChatGPT.app when the PATH shim is unavailable.
- Added a dark liquid-glass app icon with a ChatGPT-inspired interlocking mark and timer hand.
- Refined usage colors, enlarged the popover refresh control, and tightened session-row switch layout.
- Enabled rows now show `Start at HH:MM` beneath the switch.
- Removed the redundant `Remaining` label, enlarged reset metadata, and changed Weekly reset metadata to a calendar date.
- Fixed session-row observation so `Start at HH:MM` appears immediately when a switch is turned on.
- Hardened scheduled continuation: recover each session's original local working directory from its private session metadata and pass it with `-C` to `codex exec resume`, preventing an automatic `continue` from starting in the menu-bar app's unrelated directory.
- Verified the CLI continuation flow against a real Codex Desktop-originated local task: the selected session received `continue` and resumed in its original repository without requiring Accessibility permission.
- Added live local continuation observability: Queued/Starting/Running/Completed/Failed state, last-output preview, exit code, and completion notifications. Session titles now open their matching Codex Desktop task rather than spawning a Terminal window.
- Made continuation switches one-shot to prevent duplicate prompts after an app refresh or restart, and added a user-level LaunchAgent for login launch plus abnormal-exit recovery.
- Reworked continuation persistence: queued and active switches now survive a manual Quit or abnormal restart for up to seven hours, reconcile against local `task_complete` events, and retain their original scheduled time. Added refresh de-duplication and clearer in-popover lifecycle guidance.
- Fixed automatic continuation for large Desktop-originated session metadata: complete JSONL metadata reading now preserves the original working directory instead of truncating it at 16 KiB and causing a trusted-directory CLI failure. Added CLI-location discovery and a controlled no-repository fallback.
