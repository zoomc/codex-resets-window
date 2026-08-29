#!/usr/bin/env bash
#
# Layer-3 acceptance test: the real Codex CLI, the real API, two brand-new throwaway sessions.
#
# Why this exists
#   The sandbox (Scripts/sandbox-test.sh) proves the *scheduler* is correct, but it uses a stub
#   CLI — so it can never prove that `codex exec resume <id>` truly continues the same
#   conversation. This test does, and it also replays the exact scenario the app exists for:
#   a task is running, the limit hits, the app stops it; the window reopens, the app continues it.
#
# The scenario
#   1. two brand-new sessions answer a trivial prompt (cheapest model, lowest reasoning)
#   2. the app resumes both, telling the model to append 12 numbers to counter.txt with a
#      `sleep 2` between them — the watchdog cuts both off mid-task, exactly like a limit hit
#   3. the app resumes both again with a bare "continue"; only the conversation's own context
#      tells the model where it left off
#   4. counter.txt must be a strictly increasing run starting at 1
#
# Safety — nothing here can disturb work already running in ChatGPT
#   · two brand-new sessions in two brand-new git repos under $TMPDIR; no existing session is
#     read, resumed or written
#   · cheapest model, lowest reasoning effort (gpt-5.6-luna / low)
#   · the model may only write inside its own workspace (sandbox = workspace-write)
#   · the app runs with CRW_SANDBOX=1 + a private UserDefaults suite + a private process ledger,
#     so it arms nothing and adopts nothing from your real setup
#   · side effects left behind: two extra session files in ~/.codex and a temp dir
#
# Usage: Scripts/live-test.sh [--keep]
# Not run by default — `Scripts/verify.sh --live` opts in.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/CodexResetsWindow"

CODEX_BIN="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"
[[ -x "$CODEX_BIN" ]] || CODEX_BIN="/Applications/Codex.app/Contents/Resources/codex"
[[ -x "$CODEX_BIN" ]] || CODEX_BIN="$(command -v codex || true)"

MODEL="${CRW_LIVE_MODEL:-gpt-5.6-luna}"
EFFORT="${CRW_LIVE_EFFORT:-low}"
KILL_AFTER="${CRW_LIVE_KILL_AFTER:-25}"
TARGET="${CRW_LIVE_TARGET:-12}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/crw-live.XXXXXX")"
PASS=0
FAIL=0
KEEP=0
SAMPLER_PID=""

for arg in "$@"; do case "$arg" in --keep) KEEP=1 ;; esac; done

ok()  { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
note(){ printf '      %s\n' "$1"; }

cleanup() {
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null
  if [[ $KEEP -eq 0 ]]; then rm -rf "$WORK"; else echo "workdir kept at $WORK"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------

step "0. Preflight"
[[ -x "$BIN" ]] || { echo "missing $BIN — run Scripts/verify.sh first" >&2; exit 2; }
[[ -x "$CODEX_BIN" ]] || { echo "no codex CLI found; set CODEX_BIN" >&2; exit 2; }
[[ -f "$CODEX_HOME/auth.json" ]] || { echo "not logged in: $CODEX_HOME/auth.json missing" >&2; exit 2; }
ok "binary, Codex CLI ($(basename "$CODEX_BIN")) and login are present"
note "model=$MODEL reasoning_effort=$EFFORT watchdog=${KILL_AFTER}s target=${TARGET} numbers"

# The app always builds `codex -C <cwd> exec resume [--skip-git-repo-check] <id> <prompt>`,
# so the cheap-model flags have to be spliced in right after the `exec` subcommand.
WRAPPER="$WORK/bin/codex"
mkdir -p "$WORK/bin" "$WORK/logs"
cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
args=()
spliced=0
for a in "\$@"; do
  args+=("\$a")
  if [[ "\$a" == "exec" && \$spliced -eq 0 ]]; then
    args+=(-m "$MODEL" -c 'model_reasoning_effort="$EFFORT"' -s workspace-write)
    spliced=1
  fi
done
printf '%s %s\n' "\$(date +%s)" "\$*" >> "$WORK/launches.log"
exec "$CODEX_BIN" "\${args[@]}"
WRAP
chmod +x "$WRAPPER"
: > "$WORK/launches.log"
: > "$WORK/concurrency.log"
ok "built a CLI wrapper pinning the cheapest model"

# Everything the app does is confined to this private world.
run_app() {
  CRW_SANDBOX=1 \
  CRW_SUITE="crw.live.$(basename "$WORK")" \
  CRW_CODEX_HOME="$CODEX_HOME" \
  CRW_CODEX_BIN="$WRAPPER" \
  CRW_MAX_CONCURRENT=1 \
  CRW_MAX_ATTEMPTS=1 \
  CRW_KILL_GRACE=3 \
  CRW_RESET_DELAY=0 \
  CRW_RECONCILE_INTERVAL=5 \
  CRW_LOG_DIR="$WORK/logs" \
  CRW_VERBOSE=1 \
  "$@"
}

# ---------------------------------------------------------------------------------------------

make_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q . && git config user.email t@t.t && git config user.name t )
  : > "$dir/counter.txt"
}

newest_session_ids() {
  python3 - "$CODEX_HOME/session_index.jsonl" "$1" <<'PY'
import json, sys
path, marker = sys.argv[1], int(sys.argv[2])
out = []
for line in open(path).read().splitlines()[marker:]:
    if not line.strip():
        continue
    try: out.append(json.loads(line)["id"])
    except Exception: pass
print(" ".join(out))
PY
}

step "1. Open two brand-new throwaway sessions"
marker=$(wc -l < "$CODEX_HOME/session_index.jsonl" | tr -d ' ')
make_repo alpha
make_repo beta
for name in alpha beta; do
  ( cd "$WORK/$name" && "$CODEX_BIN" -C "$WORK/$name" exec \
      -m "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" -s workspace-write \
      "Reply with exactly one word: READY" > "$WORK/$name.start.log" 2>&1 ) &
done
wait
read -r SESSION_A SESSION_B <<< "$(newest_session_ids "$marker")"
if [[ -z "${SESSION_A:-}" || -z "${SESSION_B:-}" ]]; then
  bad "expected two new session ids, got '${SESSION_A:-} ${SESSION_B:-}'"
  note "alpha log:"; tail -5 "$WORK/alpha.start.log" 2>/dev/null
  exit 1
fi
ok "sessions created: ${SESSION_A:0:8}… and ${SESSION_B:0:8}…"
note "hello replies: $(tr -d '\r\n' < "$WORK/alpha.start.log" | tail -c 40) | $(tr -d '\r\n' < "$WORK/beta.start.log" | tail -c 40)"

# Count the live Codex children that belong to *these two* sessions only, so any Codex work
# already running on this machine is invisible to the measurement.
( for _ in $(seq 1 700); do
    pgrep -f "resume (${SESSION_A}|${SESSION_B})" 2>/dev/null | wc -l | tr -d ' ' >> "$WORK/concurrency.log"
    sleep 0.5
  done ) &
SAMPLER_PID=$!

# ---------------------------------------------------------------------------------------------

step "2. The app resumes both — then the watchdog cuts them off, exactly like a limit hit"
COUNT_PROMPT="Read counter.txt in the current directory and find the highest integer already there (0 if the file is empty). Then append the next ${TARGET} integers, one per line, by running exactly one shell command per number. Do not use a loop and never write more than one number per command. Right after each command, run \`sleep 2\` in its own command. Use nothing but shell commands and file writes; do not rewrite the file from scratch, only append. When all ${TARGET} numbers are written reply with exactly: LAST <highest number written>"

run_app env CRW_RUN_TIMEOUT="$KILL_AFTER" CRW_PROMPT="$COUNT_PROMPT" \
  "$BIN" --simulate $(( KILL_AFTER * 2 + 30 )) "run=$SESSION_A" "run=$SESSION_B" \
  > "$WORK/round1.log" 2>&1
note "$(grep -cE 'ARGS|exec resume' "$WORK/round1.log" 2>/dev/null) launch lines logged"
grep -E 'Timed out|watchdog|Completed|Failed' "$WORK/round1.log" | tail -4 | while read -r l; do note "$l"; done

after_a=$(grep -c . "$WORK/alpha/counter.txt" || true)
after_b=$(grep -c . "$WORK/beta/counter.txt" || true)
note "alpha=$after_a  beta=$after_b of $TARGET"
if [[ "$after_a" -gt 0 && "$after_a" -lt "$TARGET" ]]; then
  ok "alpha was stopped mid-task ($after_a of $TARGET numbers written)"
else
  bad "alpha should be stopped mid-task, got $after_a of $TARGET"
fi

peak=$(sort -n "$WORK/concurrency.log" 2>/dev/null | tail -1)
if [[ "${peak:-0}" -le 1 ]]; then
  ok "never more than one Codex child at a time (peak $peak)"
else
  bad "concurrency cap breached: peak $peak simultaneous children"
fi

# ---------------------------------------------------------------------------------------------

step "3. The window reopens — the app resumes both again with a bare \"continue\""
# No instruction is repeated here. Only the conversation's own memory can tell the model where
# it left off, which is precisely what this test is about.
before_a=$after_a
before_b=$after_b

run_app env CRW_RUN_TIMEOUT=$(( TARGET * 6 )) CRW_PROMPT=continue \
  "$BIN" --simulate $(( TARGET * 18 )) "run=$SESSION_A" "run=$SESSION_B" \
  > "$WORK/round2.log" 2>&1
grep -E 'Completed|Failed|Timed out' "$WORK/round2.log" | tail -4 | while read -r l; do note "$l"; done

kill "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""
final_a=$(grep -c . "$WORK/alpha/counter.txt" || true)
final_b=$(grep -c . "$WORK/beta/counter.txt" || true)
note "alpha $before_a -> $final_a   beta $before_b -> $final_b"

if [[ "$final_a" -gt "$before_a" ]]; then
  ok "alpha picked up where it was stopped"
else
  bad "alpha did not continue ($before_a -> $final_a)"
fi
if [[ "$final_b" -gt "$before_b" ]]; then
  ok "beta picked up where it was stopped"
else
  bad "beta did not continue ($before_b -> $final_b)"
fi

# ---------------------------------------------------------------------------------------------

step "4. The continuation really continued the conversation"
check() {
  python3 - "$WORK/alpha/counter.txt" "$WORK/beta/counter.txt" <<'PY'
import sys
good = True
for path in sys.argv[1:]:
    values = [int(l) for l in open(path).read().split() if l.strip().lstrip('-').isdigit()]
    label = path.split("/")[-2]
    strictly = all(b == a + 1 for a, b in zip(values, values[1:]))
    starts_at_one = bool(values) and values[0] == 1
    print(f"      {label}: {len(values)} numbers, strictly increasing={strictly}, starts at 1={starts_at_one}")
    if not values or not strictly or not starts_at_one:
        good = False
sys.exit(0 if good else 1)
PY
}
if check; then
  ok "both counters climb from 1 without a gap or a repeat"
else
  bad "the counters are broken — the resume restarted instead of continuing"
  note "alpha: $(tr '\n' ' ' < "$WORK/alpha/counter.txt")"
  note "beta:  $(tr '\n' ' ' < "$WORK/beta/counter.txt")"
fi

peak=$(sort -n "$WORK/concurrency.log" 2>/dev/null | tail -1)
if [[ "${peak:-0}" -le 1 ]]; then
  ok "concurrency held across both rounds (peak $peak)"
else
  bad "concurrency cap breached across rounds: peak $peak"
fi

if ! grep -q "CRW_" "$WORK/launches.log" 2>/dev/null; then
  ok "no CRW_* test variable leaked into a Codex child"
else
  bad "CRW_* leaked into a child process"
fi

# ---------------------------------------------------------------------------------------------

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32m✓ live test: %d checks passed\033[0m\n' "$PASS"
  printf '   throwaway sessions %s / %s — safe to delete from ~/.codex.\n' \
    "${SESSION_A:0:8}" "${SESSION_B:0:8}"
  exit 0
fi
printf '\033[31m✗ live test: %d failed, %d passed\033[0m\n' "$FAIL" "$PASS"
note "round1: $WORK/round1.log   round2: $WORK/round2.log   launches: $WORK/launches.log"
KEEP=1
exit 1
