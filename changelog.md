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
