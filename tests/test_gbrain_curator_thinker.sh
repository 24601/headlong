#!/usr/bin/env bash
# Focused, network-free tests for the disabled-by-default GBrain curator.
# shellcheck disable=SC2016 # bash -c snippets intentionally expand in the child
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/gbrain-curator/step"
pass=0 fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ID="$WORK/identity"
TRAJ_ID="feed0000-0000-4000-8000-00000000cafe"
TRAJ="$WORK/trajectory.jsonl"
mkdir -p "$ID/memories" "$ID/skills" "$ID/kernel" "$ID/trajectories" "$WORK/bin"
: > "$TRAJ"

cat > "$WORK/bin/traj" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == path ]] || exit 1
printf '%s\n' "$TRAJECTORY_FILE"
EOF
cat > "$WORK/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GBRAIN_CALLS"
[[ "$1" == call && "$2" == extract_facts ]] || exit 9
printf '%s\n' "$3" >> "$GBRAIN_PAYLOADS"
[[ "${GBRAIN_EXIT:-0}" == 0 ]] || exit "$GBRAIN_EXIT"
if [[ -n "${GBRAIN_RESPONSE:-}" ]]; then
    printf '%s\n' "$GBRAIN_RESPONSE"
else
    printf '%s\n' '{"status":"ok","inserted":1}'
fi
EOF
chmod +x "$WORK/bin/traj" "$WORK/bin/gbrain"

export PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export IDENTITY_DIR="$ID" IDENTITY_NAME="synthetic-identity" MEM_DIR="$ID/memories"
export TRAJ_DIR="$ID/trajectories" TRAJ_ID ROOT_TRAJ_ID="$TRAJ_ID"
export SKILLS_DIR="$ID/skills" SKILLS_KERNEL_DIR="$ID/kernel"
export TRAJECTORY_FILE="$TRAJ" GBRAIN_CALLS="$WORK/calls" GBRAIN_PAYLOADS="$WORK/payloads"
export GBRAIN_CURATOR_STATE_DIR="$WORK/state"
export GBRAIN_CURATOR_MIN_LINES=3 GBRAIN_CURATOR_MIN_BYTES=999999 GBRAIN_CURATOR_FLUSH_SECONDS=300
unset GBRAIN_CURATOR_BACKFILL GBRAIN_CURATOR_MAX_LINES GBRAIN_CURATOR_MAX_BYTES GBRAIN_EXIT GBRAIN_RESPONSE

append() { printf '%s\n' "$1" >> "$TRAJ"; }
run_step() { printf '%s' '{}' | "$STEP" >/dev/null 2>"$WORK/stderr"; }
cursor() { jq -r '.offset' "$GBRAIN_CURATOR_STATE_DIR/cursor.json"; }
calls() { if [[ -f "$GBRAIN_CALLS" ]]; then wc -l < "$GBRAIN_CALLS" | tr -d ' '; else printf 0; fi; }
reset_state() { rm -rf "$GBRAIN_CURATOR_STATE_DIR"; : > "$GBRAIN_CALLS"; : > "$GBRAIN_PAYLOADS"; }

check "bundled thinker has disabled marker" test -f "$REPO/thinkers/gbrain-curator/disabled"
check "step is executable" test -x "$STEP"
check "subscription suppresses self-triggering" jq -e '.trigger_self == false' "$REPO/thinkers/gbrain-curator/subscriptions.jsonl"

# Prospective mode initializes at current EOF and does not call GBrain.
append '{"type":"thought","step_id":"old-1","ts":"2026-01-01T00:00:00Z","content":"Synthetic old idea."}'
eof=$(wc -c < "$TRAJ" | tr -d ' ')
run_step
check "first run starts prospectively at EOF" test "$(cursor)" = "$eof"
check "prospective initialization makes no extraction call" test "$(calls)" = 0

# A later wake drains all intervening records in one structured call, filters
# machinery, and preserves attribution labels and deterministic provenance.
append '{"type":"thought","source":"identity","step_id":"new-1","ts":"2026-01-02T03:04:05Z","content":"I prefer synthetic tea."}'
run_step
check "low-volume activity waits for a batch" test "$(calls)" = 0
check "debounced activity does not advance cursor" test "$(cursor)" = "$eof"
append '{"type":"shellm-run","source":"runtime","step_id":"machine-1","content":"SYNTHETIC_MACHINERY_SECRET"}'
append '{"type":"message","from":"human","step_id":"new-2","ts":"2026-01-02T03:05:00Z","content":"I will attend the synthetic event."}'
end=$(wc -c < "$TRAJ" | tr -d ' ')
run_step
check "one batch call handles multiple delivered events" test "$(calls)" = 1
payload=$(tail -1 "$GBRAIN_PAYLOADS")
printf '%s' "$payload" > "$WORK/last-payload.json"
check "uses exact extract_facts operation" grep -qx 'call extract_facts .*' "$GBRAIN_CALLS"
check "payload sets private visibility" jq -e '.visibility == "private"' "$WORK/last-payload.json"
check "payload uses deterministic session and slug-safe provenance" jq -e --arg tid "$TRAJ_ID" --argjson s "$eof" --argjson e "$end" '.session_id == ("headlong-curator-" + $tid + "-" + ($s|tostring) + "-" + ($e|tostring)) and .source_slug == ("headlong/trajectory-" + $tid)' "$WORK/last-payload.json"
check "policy marks external context untrusted" bash -c 'printf "%s" "$1" | jq -er ".turn_text | contains(\"untrusted trajectory context\")" >/dev/null' _ "$payload"
check "type source timestamp and step id labels preserved" bash -c 'printf "%s" "$1" | jq -er ".turn_text | contains(\"[type=thought source=identity timestamp=2026-01-02T03:04:05Z step-id=new-1]\")" >/dev/null' _ "$payload"
check "machinery excluded from extraction text" bash -c 'printf "%s" "$1" | jq -er ".turn_text | contains(\"SYNTHETIC_MACHINERY_SECRET\") | not" >/dev/null' _ "$payload"
check "cursor advances after structural success" test "$(cursor)" = "$end"
check "receipt contains range trajectory status and counts" jq -e --arg tid "$TRAJ_ID" --argjson s "$eof" --argjson e "$end" '.trajectory_id == $tid and .byte_range == {start:$s,end:$e} and .status == "ok" and .counts.inserted == 1' "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"
check "receipt stores no raw batch text" bash -c '! grep -q "synthetic tea\|synthetic event\|turn_text" "$1"' _ "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"

# Explicit backfill begins at zero; line budget consumes only complete records.
reset_state
export GBRAIN_CURATOR_BACKFILL=1 GBRAIN_CURATOR_MAX_LINES=1 GBRAIN_CURATOR_MIN_LINES=1
run_step
first_line_bytes=$(head -1 "$TRAJ" | wc -c | tr -d ' ')
check "explicit backfill starts at zero" test "$(cursor)" = "$first_line_bytes"
check "line budget limits one run" test "$(calls)" = 1
check "backfill first payload contains historical record only" bash -c 'p=$(head -1 "$1"); printf "%s" "$p" | jq -er ".turn_text | contains(\"Synthetic old idea.\") and (contains(\"synthetic tea\")|not)" >/dev/null' _ "$GBRAIN_PAYLOADS"

# Zero insertions are successful and advance.
reset_state
export GBRAIN_CURATOR_MAX_LINES=40 GBRAIN_RESPONSE='{"status":"ok","inserted":0,"duplicates":2}'
run_step
check "zero insertion success advances cursor" test "$(cursor)" = "$end"
check "zero insertion receipt records counts" jq -e '.counts.inserted == 0 and .counts.duplicate == 2' "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"

# Skipped/unavailable and process errors retain the initial zero cursor. Retry
# uses the identical deterministic payload and succeeds through GBrain dedupe.
reset_state
export GBRAIN_RESPONSE='{"skipped":"extraction_unavailable"}'
run_step
check "unavailable extraction retains cursor" test "$(cursor)" = 0
first_payload=$(tail -1 "$GBRAIN_PAYLOADS")
run_step
check "unavailable signal is emitted only once" test "$(wc -c < "$WORK/stderr" | tr -d ' ')" = 0
check "retry payload is deterministic" test "$(tail -1 "$GBRAIN_PAYLOADS")" = "$first_payload"
export GBRAIN_RESPONSE='{"status":"ok","inserted":1}'
run_step
check "retry succeeds and advances" test "$(cursor)" = "$end"

reset_state
export GBRAIN_EXIT=7 GBRAIN_RESPONSE='{"status":"ok"}'
run_step
check "gbrain process error retains cursor" test "$(cursor)" = 0

# Batches containing only machinery or this thinker's output are consumed
# locally, never sent back to GBrain, and therefore cannot form a loop.
: > "$TRAJ"; reset_state; unset GBRAIN_EXIT GBRAIN_RESPONSE
export GBRAIN_CURATOR_MIN_LINES=1
append '{"type":"run-summary","step_id":"m-1","content":"summary"}'
append '{"type":"observation","source":"gbrain-curator","step_id":"m-2","content":"curator output"}'
only_end=$(wc -c < "$TRAJ" | tr -d ' ')
run_step
check "own output and machinery make no GBrain call" test "$(calls)" = 0
check "filtered-only batch advances to avoid loops" test "$(cursor)" = "$only_end"
check "filtered receipt contains no raw content" bash -c '! grep -q "summary\|curator output" "$1"' _ "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
