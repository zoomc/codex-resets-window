# Agent guidance

Codex Resets Window is a privacy-first macOS menu-bar app. Keep all session content, tokens, account IDs, and email addresses out of the repository, UI logs, screenshots, and tests.

Run `Scripts/verify.sh` after source changes. It builds the release binary, runs the deterministic
in-process suite, and exercises the shipped scheduler in an isolated sandbox. Use
`Scripts/verify.sh --live` only with explicit approval because it creates real throwaway Codex
sessions and consumes account capacity. Prefer standard macOS frameworks; do not add third-party
dependencies without a clear need.
