#!/usr/bin/env bash
# Network-free safety and durability tests for the disabled GBrain curator.
# shellcheck disable=SC2016 # bash -c snippets expand in the child by design
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/gbrain-curator/step"
pass=0 fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ID="$WORK/identity"
TRAJ_ID="feed0000-0000-4000-8000-00000000cafe"
TRAJ="$WORK/trajectory.jsonl"
mkdir -p "$ID/memories" "$ID/skills" "$ID/kernel" "$ID/trajectories" "$ID/run" "$WORK/bin"
: > "$TRAJ"

cat > "$WORK/bin/traj" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == path ]] || exit 1
printf '%s\n' "$TRAJECTORY_FILE"
EOF
cat > "$WORK/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$GBRAIN_CALLS"; printf '\n' >> "$GBRAIN_CALLS"
[[ "$#" == 3 && "$1" == call && "$2" == --stdin && "$3" == extract_facts ]] || exit 9
cat > "$GBRAIN_LAST_STDIN"
cat "$GBRAIN_LAST_STDIN" >> "$GBRAIN_PAYLOADS"; printf '\n' >> "$GBRAIN_PAYLOADS"
find "$GBRAIN_CURATOR_STATE_DIR" -maxdepth 1 -type f -name 'payload.*' -printf '%m\n' >> "$GBRAIN_MODES" 2>/dev/null || true
if [[ -n "${GBRAIN_SLEEP:-}" ]]; then
    trap 'printf terminated > "$GBRAIN_TERMINATED"; exit 143' TERM
    printf '%s' "$$" > "$GBRAIN_PID"
    sleep "$GBRAIN_SLEEP"
fi
[[ "${GBRAIN_EXIT:-0}" == 0 ]] || exit "$GBRAIN_EXIT"
if [[ -n "${GBRAIN_RESPONSE:-}" ]]; then
    printf '%s\n' "$GBRAIN_RESPONSE"
else
    printf '%s\n' '{"inserted":1,"duplicate":0,"superseded":0,"fact_ids":["synthetic-id"]}'
fi
EOF
chmod +x "$WORK/bin/traj" "$WORK/bin/gbrain"

export PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export IDENTITY_DIR="$ID" IDENTITY_NAME="synthetic-identity" MEM_DIR="$ID/memories"
export TRAJ_DIR="$ID/trajectories" TRAJ_ID ROOT_TRAJ_ID="$TRAJ_ID"
export SKILLS_DIR="$ID/skills" SKILLS_KERNEL_DIR="$ID/kernel"
export TRAJECTORY_FILE="$TRAJ" GBRAIN_CALLS="$WORK/calls" GBRAIN_PAYLOADS="$WORK/payloads"
export GBRAIN_LAST_STDIN="$WORK/stdin" GBRAIN_MODES="$WORK/modes"
export GBRAIN_PID="$WORK/gbrain.pid" GBRAIN_TERMINATED="$WORK/terminated"
export GBRAIN_CURATOR_STATE_DIR="$WORK/state"
export GBRAIN_CURATOR_MIN_LINES=1 GBRAIN_CURATOR_MIN_BYTES=1 GBRAIN_CURATOR_FLUSH_SECONDS=2
export GBRAIN_CURATOR_MAX_LINES=40 GBRAIN_CURATOR_MAX_BYTES=65536
export GBRAIN_CURATOR_MAX_REQUEST_BYTES=131072 GBRAIN_CURATOR_TIMEOUT_SECONDS=5
export GBRAIN_CURATOR_MAX_RESPONSE_BYTES=65536
export GBRAIN_CURATOR_RETRY_BASE_SECONDS=30 GBRAIN_CURATOR_RETRY_CAP_SECONDS=60
export GBRAIN_CURATOR_BACKFILL=1
unset GBRAIN_CURATOR_TYPES GBRAIN_RESPONSE GBRAIN_EXIT GBRAIN_SLEEP
printf token > "$ID/run/dispatcher.token"

append() { printf '%s\n' "$1" >> "$TRAJ"; }
run_step() { : > "$WORK/stderr"; printf '%s' '{}' | "$STEP" >/dev/null 2>"$WORK/stderr"; }
cursor() { jq -r '.offset' "$GBRAIN_CURATOR_STATE_DIR/cursor.json"; }
calls() { if [[ -f "$GBRAIN_CALLS" ]]; then wc -l < "$GBRAIN_CALLS" | tr -d ' '; else printf 0; fi; }
reset_state() {
    rm -rf "$GBRAIN_CURATOR_STATE_DIR"
    mkdir -p "$GBRAIN_CURATOR_STATE_DIR"
    : > "$GBRAIN_CALLS"; : > "$GBRAIN_PAYLOADS"; : > "$GBRAIN_MODES"
    rm -f "$GBRAIN_LAST_STDIN" "$GBRAIN_PID" "$GBRAIN_TERMINATED" "$ID/run/gbrain-curator.wake_at"
    unset GBRAIN_RESPONSE GBRAIN_EXIT GBRAIN_SLEEP GBRAIN_CURATOR_TYPES
}
force_retry_due() { jq '.next_at = 0' "$GBRAIN_CURATOR_STATE_DIR/retry.json" > "$WORK/retry" && mv "$WORK/retry" "$GBRAIN_CURATOR_STATE_DIR/retry.json"; }

check "bundled thinker remains disabled" test -f "$REPO/thinkers/gbrain-curator/disabled"
check "step is executable" test -x "$STEP"
check "subscription suppresses self-triggering" jq -e '.trigger_self == false' "$REPO/thinkers/gbrain-curator/subscriptions.jsonl"

# True happy path: exact argv, private JSON only on stdin, filtering, receipt,
# cursor commit, bounded permissions, and no duplicate extraction on wake two.
append '{"type":"thought","source":"identity","step_id":"t-1","ts":"2026-01-02T03:04:05Z","content":"I prefer synthetic tea."}'
append '{"type":"observation","source":"feed","step_id":"o-1","content":"PRIVATE_OBSERVATION"}'
append '{"type":"shellm-run","source":"runtime","step_id":"m-1","content":"PRIVATE_MACHINERY"}'
end=$(wc -c < "$TRAJ" | tr -d ' ')
run_step
check "valid extraction makes one call" test "$(calls)" = 1
check "argv is exact and contains no payload" grep -qx 'call --stdin extract_facts ' "$GBRAIN_CALLS"
check "stdin is valid private payload" jq -e '.visibility == "private" and (.turn_text | contains("synthetic tea"))' "$GBRAIN_LAST_STDIN"
check "observation excluded by default" bash -c '! grep -q PRIVATE_OBSERVATION "$1"' _ "$GBRAIN_LAST_STDIN"
check "machinery excluded" bash -c '! grep -q PRIVATE_MACHINERY "$1"' _ "$GBRAIN_LAST_STDIN"
check "historical timestamp label preserved" grep -q 'timestamp=2026-01-02T03:04:05Z' "$GBRAIN_LAST_STDIN"
check "cursor advances once after verified response" test "$(cursor)" = "$end"
check "one nonempty bounded receipt is written" bash -c '[[ $(wc -l < "$1") == 1 && -s "$1" && $(wc -c < "$1") -lt 1024 ]]' _ "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"
check "receipt has strict counts and no private text" bash -c 'jq -e ".counts == {inserted:1,duplicate:0,superseded:0} and .fact_id_count == 1" "$1" >/dev/null && ! grep -q "synthetic tea\|turn_text" "$1"' _ "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"
check "payload temp file mode is 0600" grep -qx 600 "$GBRAIN_MODES"
run_step
check "duplicate wake does not re-extract" test "$(calls)" = 1
check "duplicate wake does not add receipt" test "$(wc -l < "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl")" = 1

# Source-self records are consumed locally and cannot feed the curator back
# into itself, even if their type is otherwise eligible.
: > "$TRAJ"; reset_state
append '{"type":"message","source":"gbrain-curator","content":"PRIVATE_SELF_OUTPUT"}'
self_end=$(wc -c < "$TRAJ" | tr -d ' ')
run_step
check "source-self record makes no call" test "$(calls)" = 0
check "source-self record advances with filtered receipt" test "$(cursor)" = "$self_end"
check "filtered receipt contains no self output" bash -c '! grep -q PRIVATE_SELF_OUTPUT "$1"' _ "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"

# Restore the original fixture for receipt-first recovery.
: > "$TRAJ"
append '{"type":"thought","source":"identity","step_id":"t-1","ts":"2026-01-02T03:04:05Z","content":"I prefer synthetic tea."}'
append '{"type":"observation","source":"feed","step_id":"o-1","content":"PRIVATE_OBSERVATION"}'
append '{"type":"shellm-run","source":"runtime","step_id":"m-1","content":"PRIVATE_MACHINERY"}'

# Receipt-first crash recovery advances without another call or receipt.
reset_state
jq -nc --arg tid "$TRAJ_ID" '{version:1,trajectory_id:$tid,offset:0}' > "$GBRAIN_CURATOR_STATE_DIR/cursor.json"
jq -nc --arg tid "$TRAJ_ID" --argjson end_offset "$end" '{trajectory_id:$tid,byte_range:{start:0,end:$end_offset},status:"ok",counts:{inserted:1,duplicate:0,superseded:0}}' > "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl"
run_step
check "receipt-first recovery advances cursor" test "$(cursor)" = "$end"
check "receipt-first recovery does not call GBrain" test "$(calls)" = 0
check "receipt-first recovery does not duplicate receipt" test "$(wc -l < "$GBRAIN_CURATOR_STATE_DIR/receipts.jsonl")" = 1

# Torn, malformed, and oversized records never advance or leak into a request.
: > "$TRAJ"; reset_state
printf '%s' '{"type":"thought","content":"torn"}' > "$TRAJ"
run_step
check "torn final line retains cursor" test "$(cursor)" = 0
check "torn final line makes no call" test "$(calls)" = 0
printf '\n' >> "$TRAJ"; complete_end=$(wc -c < "$TRAJ" | tr -d ' ')
run_step
check "completed torn line is later extracted" test "$(cursor)" = "$complete_end"

: > "$TRAJ"; reset_state; printf '%s\n' '{not-json}' > "$TRAJ"; run_step
check "malformed complete record retains cursor" test "$(cursor)" = 0
check "malformed record emits bounded signal" bash -c '[[ -s "$1" && $(wc -c < "$1") -lt 256 ]]' _ "$GBRAIN_CURATOR_STATE_DIR/operator-signal"
check "malformed record schedules retry" test -s "$ID/run/gbrain-curator.wake_at"

: > "$TRAJ"; reset_state; export GBRAIN_CURATOR_MAX_BYTES=256
printf '{"type":"thought","content":"' > "$TRAJ"; head -c 300 /dev/zero | tr '\0' x >> "$TRAJ"; printf '"}\n' >> "$TRAJ"
run_step
check "oversized complete record retains cursor" test "$(cursor)" = 0
check "oversized record makes no call" test "$(calls)" = 0
check "oversized record signals operator" grep -q 'exceeds the byte limit' "$GBRAIN_CURATOR_STATE_DIR/operator-signal"
export GBRAIN_CURATOR_MAX_BYTES=65536

: > "$TRAJ"; reset_state; export GBRAIN_CURATOR_MAX_REQUEST_BYTES=1024
long_text=$(head -c 1600 /dev/zero | tr '\0' q)
append "{\"type\":\"thought\",\"content\":\"$long_text\"}"
run_step
check "oversized total request retains cursor" test "$(cursor)" = 0
check "oversized total request is never invoked" test "$(calls)" = 0
export GBRAIN_CURATOR_MAX_REQUEST_BYTES=131072

: > "$TRAJ"; reset_state; export GBRAIN_CURATOR_MAX_RESPONSE_BYTES=1024
append '{"type":"thought","content":"bounded response probe"}'
large_id=$(head -c 1400 /dev/zero | tr '\0' z)
export GBRAIN_RESPONSE="{\"inserted\":1,\"duplicate\":0,\"superseded\":0,\"fact_ids\":[\"$large_id\"]}"
run_step
check "oversized response retains cursor" test "$(cursor)" = 0
check "oversized response body is not persisted" bash -c '! grep -R -q "zzzzzzzzzz" "$1"' _ "$GBRAIN_CURATOR_STATE_DIR"
export GBRAIN_CURATOR_MAX_RESPONSE_BYTES=65536

# Every non-documented response shape retains the cursor.
: > "$TRAJ"; append '{"type":"message","from":"human","content":"schema probe"}'
invalid_responses=(
    '{}'
    '{"result":{"inserted":1,"duplicate":0,"superseded":0,"fact_ids":[]}}'
    '{"inserted":1,"duplicate":0,"superseded":0}'
    '{"inserted":"1","duplicate":0,"superseded":0,"fact_ids":[]}'
    '{"inserted":1,"duplicate":0,"superseded":0,"fact_ids":[],"skipped":false}'
    '{"inserted":1,"duplicate":0,"superseded":0,"fact_ids":[],"error":null}'
    'not-json'
)
for response in "${invalid_responses[@]}"; do
    reset_state; export GBRAIN_RESPONSE="$response"; run_step
    if [[ "$(cursor)" == 0 ]]; then ok "strict schema rejects: $response"; else bad "strict schema rejects: $response"; fi
done

# Timeout kills the child, retains cursor, signals once, and schedules backoff.
reset_state; export GBRAIN_SLEEP=5 GBRAIN_CURATOR_TIMEOUT_SECONDS=1
run_step
sleep 1
check "timeout retains cursor" test "$(cursor)" = 0
check "timeout terminates child" test -s "$GBRAIN_TERMINATED"
check "timeout schedules retry" test -s "$ID/run/gbrain-curator.wake_at"
first_signal=$(cat "$GBRAIN_CURATOR_STATE_DIR/operator-signal")
run_step
check "backoff suppresses per-event retry calls" test "$(calls)" = 1
check "operator signal is emitted once" test "$(cat "$GBRAIN_CURATOR_STATE_DIR/operator-signal")" = "$first_signal"
unset GBRAIN_SLEEP; export GBRAIN_CURATOR_TIMEOUT_SECONDS=5
force_retry_due; run_step
check "scheduled retry later succeeds" test "$(cursor)" = "$(wc -c < "$TRAJ" | tr -d ' ')"

# Sparse pending data receives a wake and flushes without another trajectory event.
reset_state; export GBRAIN_CURATOR_MIN_LINES=5 GBRAIN_CURATOR_MIN_BYTES=65536
run_step
check "sparse batch does not call immediately" test "$(calls)" = 0
check "sparse batch persists only structural pending time" grep -Eq '^[0-9]+$' "$GBRAIN_CURATOR_STATE_DIR/pending-since"
check "sparse batch arms generic wake_at" grep -Eq '^[0-9]+$' "$ID/run/gbrain-curator.wake_at"
printf '%s\n' "$(( $(date +%s) - 3 ))" > "$GBRAIN_CURATOR_STATE_DIR/pending-since"
run_step
check "scheduled sparse wake flushes without new event" test "$(calls)" = 1
export GBRAIN_CURATOR_MIN_LINES=1 GBRAIN_CURATOR_MIN_BYTES=1

# Observation expansion is explicit, validated, and bounded.
: > "$TRAJ"; reset_state; append '{"type":"observation","source":"trusted-local","content":"EXPLICIT_OBSERVATION"}'
export GBRAIN_CURATOR_TYPES='["observation"]'; run_step
check "explicit observation opt-in is honored" grep -q EXPLICIT_OBSERVATION "$GBRAIN_LAST_STDIN"
reset_state; export GBRAIN_CURATOR_TYPES='["shellm-run"]'; run_step
check "unsafe type expansion retains cursor" test "$(cursor 2>/dev/null || printf 0)" = 0
check "unsafe type expansion signals once" grep -q 'GBRAIN_CURATOR_TYPES is invalid' "$GBRAIN_CURATOR_STATE_DIR/operator-signal"

# Missing dependency is explicit, bounded, retryable, and reads no trajectory.
reset_state
NODEPS="$WORK/nodeps"; mkdir -p "$NODEPS"
for command in bash dirname realpath mkdir date mv gbrain traj jq timeout; do
    target=$(command -v "$command"); ln -sf "$target" "$NODEPS/$command"
done
ln -sf /usr/bin/true "$NODEPS/true"
saved_path="$PATH"; PATH="$NODEPS" run_step
check "missing perl emits bounded signal" grep -q 'missing required dependencies (perl)' "$GBRAIN_CURATOR_STATE_DIR/operator-signal"
check "missing dependency retains retry state" test -s "$GBRAIN_CURATOR_STATE_DIR/retry.json"
check "missing dependency makes no GBrain call" test "$(calls)" = 0
PATH="$saved_path"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
