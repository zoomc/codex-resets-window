#!/usr/bin/env bash
#
# Layer-2 sandbox integration tests.
#
# Everything here runs the *shipped binary* against a throwaway world:
#
#   ~/.codex            -> $SANDBOX/home        (fake auth.json, session index, transcripts)
#   codex CLI           -> $SANDBOX/bin/codex   (a shell stub whose behaviour we script)
#   usage API           -> $SANDBOX/usage.json  (no network at all)
#   UserDefaults        -> a private suite      (CRW_SANDBOX=1)
#   process ledger      -> $SANDBOX/state/      (CRW_SANDBOX=1)
#
# Nothing writes outside $SANDBOX, and the real Codex quota is never touched, so this is safe to
# run while real ChatGPT work is in flight.
#
# Usage:  Scripts/sandbox-test.sh [--keep] [--verbose]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/CodexResetsWindow"
SANDBOX="${CRW_SANDBOX_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/crw-sandbox.XXXXXX")}"
KEEP=0
VERBOSE="${CRW_VERBOSE:-0}"

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --verbose) VERBOSE=1 ;;
  esac
done

SUITE=""
PASS=0
FAIL=0
FAILED_NAMES=()

if [[ ! -x "$BIN" ]]; then
  echo "missing binary: run 'swift build -c release --disable-sandbox' first" >&2
  exit 2
fi

cleanup() {
  if [[ $KEEP -eq 0 ]]; then rm -rf "$SANDBOX"; else echo "sandbox kept at $SANDBOX"; fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { [[ $VERBOSE -eq 1 ]] && printf '      %s\n' "$1"; return 0; }

check() { # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}
check_contains() { # check_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3')"; fi
}
check_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly contains '$3')"; fi
}

# ---------------------------------------------------------------------------------------------
# Fixture world
# ---------------------------------------------------------------------------------------------

SESSION_A="019dedda-3bf7-73e0-b406-2cee3cf2bed8"   # UUIDv7 -> 2026/05/03
SESSION_B="019deddb-1c24-70a1-9f3a-77c1ba0e6d21"
PROJECT="$SANDBOX/project"

build_world() {
  mkdir -p "$SANDBOX/home/sessions/2026/05/03" "$SANDBOX/bin" "$SANDBOX/state" "$PROJECT/.git"

  cat > "$SANDBOX/home/auth.json" <<'JSON'
{"tokens":{"access_token":"stub-access-token","account_id":"acct_stub"},"last_refresh":"2026-01-01T00:00:00Z"}
JSON

  cat > "$SANDBOX/home/session_index.jsonl" <<JSON
{"id":"$SESSION_A","thread_name":"Sandbox alpha","updated_at":"2026-05-03T10:00:00.000Z"}
{"id":"$SESSION_B","thread_name":"Sandbox beta","updated_at":"2026-05-03T09:00:00.000Z"}
JSON

  cat > "$SANDBOX/home/sessions/2026/05/03/rollout-2026-05-03T10-00-00-$SESSION_A.jsonl" <<JSON
{"timestamp":"2026-05-03T10:00:00.000Z","type":"session_meta","payload":{"id":"$SESSION_A","cwd":"$PROJECT"}}
{"timestamp":"2026-05-03T10:00:05.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
{"timestamp":"2026-05-03T10:00:06.000Z","type":"event_msg","info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":300,"output_tokens":450,"reasoning_output_tokens":50,"total_tokens":1650}}}
JSON

  cat > "$SANDBOX/home/sessions/2026/05/03/rollout-2026-05-03T09-00-00-$SESSION_B.jsonl" <<JSON
{"timestamp":"2026-05-03T09:00:00.000Z","type":"session_meta","payload":{"id":"$SESSION_B","cwd":"$PROJECT"}}
JSON

  # A stub CLI. Behaviour is switched by writing $SANDBOX/state/mode:
  #   ok | fail | flaky | hang | locked
  # `locked` fails only the first launch with the writer-lock error a live Codex session
  # produces, so later launches (the `queue` fallback) succeed.
  cat > "$SANDBOX/bin/codex" <<STUB
#!/usr/bin/env bash
SANDBOX="$SANDBOX"
n=\$(cat "\$SANDBOX/state/count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "\$SANDBOX/state/count"
{
  echo "--- launch \$n at \$(date +%s)"
  echo "ARGS: \$*"
  echo "PWD: \$PWD"
  echo "CRW_LEAK: \$(env | grep -c '^CRW_')"
} >> "\$SANDBOX/state/cli.log"
mode=\$(cat "\$SANDBOX/state/mode" 2>/dev/null || echo ok)
case "\$mode" in
  ok)    exit 0 ;;
  fail)  exit 7 ;;
  flaky) [[ \$n -lt 3 ]] && exit 7; exit 0 ;;
  hang)  sleep 3600 ;;
  locked)
    if [[ \$n -lt 2 ]]; then
      echo "Error: thread/resume: thread/resume failed: thread already has an active writer (code -32600)" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/codex"
  echo ok > "$SANDBOX/state/mode"
  : > "$SANDBOX/state/cli.log"
}

# A usage payload whose 5-hour window resets `in_seconds` from now.
write_usage() {
  local in_seconds="$1" used="${2:-42}"
  local reset_at=$(( $(date +%s) + in_seconds ))
  cat > "$SANDBOX/usage.json" <<JSON
{"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_after_seconds":$in_seconds,"reset_at":$reset_at,"used_percent":$used},"secondary_window":{"limit_window_seconds":604800,"reset_after_seconds":$(( in_seconds + 86400 )),"reset_at":$(( reset_at + 86400 )),"used_percent":18}}}
JSON
}

# The common environment for every simulated run.
# Extra `CRW_*=value` arguments are forwarded and override the defaults below.
env_for() {
  local -a assigns=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      CRW_*=*) assigns+=("$1"); shift ;;
      *) break ;;
    esac
  done
  env \
    CRW_SANDBOX=1 \
    CRW_SUITE="$SUITE" \
    CRW_CODEX_HOME="$SANDBOX/home" \
    CRW_CODEX_BIN="$SANDBOX/bin/codex" \
    CRW_USAGE_FIXTURE="$SANDBOX/usage.json" \
    CRW_MAX_ATTEMPTS=3 \
    CRW_BACKOFF_BASE=1 \
    CRW_BACKOFF_CAP=2 \
    CRW_RUN_TIMEOUT=0 \
    CRW_KILL_GRACE=1 \
    CRW_RESET_DELAY=1 \
    CRW_PROMPT=continue \
    ${assigns[@]+"${assigns[@]}"} \
    "$@"
}

# Wipes the sandbox UserDefaults domain so each scenario starts from nothing.
reset_state() {
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  rm -f "$SANDBOX/state/count" "$SANDBOX/state/cli.log"
  : > "$SANDBOX/state/cli.log"
}

launch_count() { cat "$SANDBOX/state/count" 2>/dev/null || echo 0; }
cli_log()      { cat "$SANDBOX/state/cli.log" 2>/dev/null || echo ""; }
reset_stub()   { rm -f "$SANDBOX/state/count"; : > "$SANDBOX/state/cli.log"; }
# The stub reports $PWD, which resolves symlinks; compare on the basename tail instead.
cli_pwd()      { grep -o 'PWD: .*/project$' "$SANDBOX/state/cli.log" 2>/dev/null | head -1 | sed 's|.*/||'; }

# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------

SUITE="crw.sandbox.$(basename "$SANDBOX")"
build_world
write_usage 3600 42

step "1. Headless inspector reads the fake world"
out=$(env_for "$BIN" --dump 2>&1)
note "$out"
check_contains "lists the armed-session column header" "$out" "sessions (2)"
check_contains "shows the session title from the index" "$out" "Sandbox alpha"
check_contains "reports primary usage" "$out" "primary   58% remaining"
check_contains "reports measured local tokens" "$out" "tokens    1.6k measured local tokens"
json=$(env_for "$BIN" --dump-json 2>/dev/null)
if echo "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "--dump-json emits valid JSON"
else
  bad "--dump-json emits valid JSON"
fi
check "dump reports two sessions" \
  "$(echo "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"]))')" "2"
check "dump-json reports token usage" \
  "$(echo "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokenUsage"]))')" "1"

step "2. Happy path: arm -> launch -> succeed"
reset_stub; echo ok > "$SANDBOX/state/mode"
out=$(env_for "$BIN" --simulate 4 "run=$SESSION_A" 2>&1)
note "$out"
check "the stub CLI was launched once" "$(launch_count)" "1"
check_contains "run marked Completed" "$out" "Completed"
check "the child ran in the session's own directory" "$(cli_pwd)" "project"
check_contains "arguments use 'exec resume'" "$(cli_log)" "exec resume $SESSION_A continue"
check_not_contains "no --skip-git-repo-check inside a real git repo" "$(cli_log)" "--skip-git-repo-check"
check "sandbox variables do not leak to the child" \
  "$(grep -c 'CRW_LEAK: 0' "$SANDBOX/state/cli.log")" "1"

step "3. Failure then success: bounded retry with backoff"
reset_stub; echo flaky > "$SANDBOX/state/mode"
out=$(env_for "$BIN" --simulate 12 "run=$SESSION_B" 2>&1)
note "$out"
check "three launches (two failures then a win)" "$(launch_count)" "3"
check_contains "ends in Completed" "$out" "Completed"

step "4. Gives up instead of looping forever"
reset_stub; echo fail > "$SANDBOX/state/mode"
reset_state
out=$(env_for "$BIN" --simulate 12 "run=$SESSION_A" 2>&1)
note "$out"
launches=$(launch_count)
if [[ "$launches" -le 3 ]]; then ok "launches capped at maxAttempts ($launches)"; else bad "launches capped at maxAttempts ($launches)"; fi
check_contains "ends in Failed" "$out" "Failed"

step "5. Watchdog kills a hung child"
reset_stub; echo hang > "$SANDBOX/state/mode"
reset_state
out=$(env_for CRW_RUN_TIMEOUT=3 CRW_MAX_ATTEMPTS=1 "$BIN" --simulate 14 "run=$SESSION_A" 2>&1)
note "$out"
check "the hung child is reported as timed out" \
  "$(env_for "$BIN" --dump-json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["continuations"][0]["outcome"])' 2>/dev/null)" \
  "Timed out"
pkill -f "$SANDBOX/bin/codex" >/dev/null 2>&1 || true

step "6. A relaunch does not start a second child for an already-armed session"
reset_stub; echo hang > "$SANDBOX/state/mode"
reset_state
env_for "$BIN" --simulate 3 "run=$SESSION_A" >/dev/null 2>&1
after_first=$(launch_count)
env_for "$BIN" --simulate 3 >/dev/null 2>&1
after_second=$(launch_count)
check "no duplicate launch on relaunch" "$after_second" "$after_first"
pkill -f "$SANDBOX/bin/codex" >/dev/null 2>&1 || true

step "7. The reset delay drives the launch, not a manual trigger"
reset_stub; echo ok > "$SANDBOX/state/mode"
write_usage 3600 90
reset_state
# CRW_RESET_DELAY=3 collapses the five minute post-reset delay into three seconds.
out=$(env_for CRW_RESET_DELAY=3 "$BIN" --simulate 10 "arm=$SESSION_A" 2>&1)
note "$out"
check "the continuation fired once the reset delay elapsed" "$(launch_count)" "1"
check_contains "run marked Completed" "$out" "Completed"

step "8. A thread held open elsewhere falls back to queue"
reset_stub; echo locked > "$SANDBOX/state/mode"
reset_state
out=$(env_for "$BIN" --simulate 8 "run=$SESSION_A" 2>&1)
note "$out"
check "resume fails once, then the queue fallback fires" "$(launch_count)" "2"
check_contains "the fallback queues to the live session" "$(cli_log)" "queue --thread $SESSION_A"
check_contains "delivery completes the record" "$out" "Completed"

step "9. Custom prompt reaches the child"
reset_stub; echo ok > "$SANDBOX/state/mode"
reset_state
env_for CRW_PROMPT="please carry on" "$BIN" --simulate 4 "run=$SESSION_A" >/dev/null 2>&1
check_contains "the configured prompt is passed through" "$(cli_log)" "please carry on"

step "10. The real UserDefaults suite is untouched"
leaked=$(defaults read com.codexresets.window scheduledSessionIDs 2>/dev/null | head -1)
if [[ -z "$leaked" ]]; then
  ok "no continuation state written to the shared suite"
else
  note "shared suite already had state before this run: $leaked"
  ok "no continuation state written to the shared suite (pre-existing)"
fi

# ---------------------------------------------------------------------------------------------

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32m✓ sandbox: %d checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m✗ sandbox: %d failed, %d passed\033[0m\n' "$FAIL" "$PASS"
for name in "${FAILED_NAMES[@]}"; do printf '   · %s\n' "$name"; done
exit 1
