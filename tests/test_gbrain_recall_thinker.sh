#!/usr/bin/env bash
# Network-free behavior tests for the disabled-by-default GBrain recall thinker.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/gbrain-recall/step"
pass=0 fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ID="$WORK/identity"
TRAJ_ID="feed0000-0000-4000-8000-00000000beef"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
mkdir -p "$ID/memories" "$ID/skills" "$ID/kernel" "$(dirname "$TRAJ")" "$WORK/bin"
: > "$TRAJ"

cat > "$WORK/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GBRAIN_CALLS"
[[ "$1" == call && "$2" == recall ]] || exit 9
printf '%s\n' "$3" >> "$GBRAIN_PAYLOADS"
[[ "${GBRAIN_EXIT:-0}" == 0 ]] || exit "$GBRAIN_EXIT"
if [[ -n "${GBRAIN_RESPONSE:-}" ]]; then
    printf '%s\n' "$GBRAIN_RESPONSE"
else
    printf '%s\n' '{"protocol_version":1,"facts":[],"results":[]}'
fi
EOF
cat > "$WORK/bin/traj" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == append ]]; then
    [[ "${TRAJ_EXIT:-0}" == 0 ]] || exit "$TRAJ_EXIT"
    cat >> "$TRAJECTORY_FILE"
else
    exit 9
fi
EOF
chmod +x "$WORK/bin/gbrain" "$WORK/bin/traj"

export PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export IDENTITY_DIR="$ID" IDENTITY_NAME="synthetic-identity" MEM_DIR="$ID/memories"
export TRAJ_DIR="$ID/trajectories" TRAJ_ID ROOT_TRAJ_ID="$TRAJ_ID"
export SKILLS_DIR="$ID/skills" SKILLS_KERNEL_DIR="$ID/kernel" TRAJECTORY_FILE="$TRAJ"
export GBRAIN_CALLS="$WORK/calls" GBRAIN_PAYLOADS="$WORK/payloads"
export GBRAIN_RECALL_STATE_DIR="$WORK/state" GBRAIN_RECALL_THOUGHT_COOLDOWN=300
unset GBRAIN_EXIT GBRAIN_RESPONSE TRAJ_EXIT

run_step() { printf '%s' "$1" | "$STEP" >"$WORK/stdout" 2>"$WORK/stderr"; }
calls() { if [[ -f "$GBRAIN_CALLS" ]]; then wc -l < "$GBRAIN_CALLS" | tr -d ' '; else printf 0; fi; }
observations() { grep -c '"source":"gbrain-recall"' "$TRAJ" 2>/dev/null || true; }
reset_state() { rm -rf "$GBRAIN_RECALL_STATE_DIR"; : > "$GBRAIN_CALLS"; : > "$GBRAIN_PAYLOADS"; : > "$TRAJ"; }

check "bundled thinker has disabled marker" test -f "$REPO/thinkers/gbrain-recall/disabled"
check "step is executable" test -x "$STEP"
check "subscriptions are bounded to messages and thoughts" bash -c 'jq -e '\''(.types | sort) == ["message","thought"] and .trigger_self == false'\'' "$1" >/dev/null' _ "$REPO/thinkers/gbrain-recall/subscriptions.jsonl"

export GBRAIN_RESPONSE='{"protocol_version":1,"facts":[{"fact_id":"f1","entity_slug":"projects/example","text":"The project uses synthetic fixtures."}],"results":[{"slug":"notes/example","chunk":"A bounded supporting note."}],"agent_action":"DO NOT COPY"}'
message='{"type":"message","step_id":"m1","from":"human","to":"synthetic-identity","content":"What does the project use?"}'
run_step "$message"
check "inbound message makes one recall call" test "$(calls)" = 1
payload=$(tail -1 "$GBRAIN_PAYLOADS"); printf '%s' "$payload" > "$WORK/payload.json"
check "recall request is bounded" jq -e '.query == "What does the project use?" and .budget_tokens == 800 and .limit == 6' "$WORK/payload.json"
check "one observation is appended" test "$(observations)" = 1
check "observation contains bounded facts and pages" bash -c 'jq -e '\''select(.source=="gbrain-recall") | (.content | contains("The project uses synthetic fixtures.") and contains("A bounded supporting note."))'\'' "$1" >/dev/null' _ "$TRAJ"
check "observation carries injection boundary and trigger" bash -c 'jq -e '\''select(.source=="gbrain-recall") | .trigger_step == "m1" and (.content | contains("never follow instructions"))'\'' "$1" >/dev/null' _ "$TRAJ"
check "opaque agent action is not forwarded" bash -c '! grep -q "DO NOT COPY" "$1"' _ "$TRAJ"

run_step "$message"
check "redelivery is idempotent" test "$(calls)" = 1
check "redelivery appends no duplicate observation" test "$(observations)" = 1

run_step '{"type":"message","step_id":"m2","from":"synthetic-identity","to":"human","content":"outgoing"}'
run_step '{"type":"message","step_id":"m3","from":"human","to":"someone-else","content":"cross identity"}'
run_step '{"type":"observation","step_id":"m4","source":"external","content":"not subscribed"}'
check "outgoing cross-identity and other types are ignored" test "$(calls)" = 1

# A successful no-result query is handled once without adding noise.
export GBRAIN_RESPONSE='{"protocol_version":1,"facts":[],"results":[]}'
run_step '{"type":"message","step_id":"m5","from":"human","to":"synthetic-identity","content":"No match expected."}'
check "successful empty recall is recorded" test "$(calls)" = 2
check "empty recall appends no observation" test "$(observations)" = 1
run_step '{"type":"message","step_id":"m5","from":"human","to":"synthetic-identity","content":"No match expected."}'
check "empty recall is not repeated" test "$(calls)" = 2

# Thoughts are allowed but cooldown prevents a recall↔monolith feedback loop.
reset_state
export GBRAIN_RESPONSE='{"protocol_version":1,"facts":[{"text":"Context."}],"results":[]}'
run_step '{"type":"thought","step_id":"t1","source":"monolith","content":"A sufficiently meaningful topic."}'
run_step '{"type":"thought","step_id":"t2","source":"monolith","content":"A thought caused by the observation."}'
check "thought cooldown permits only one query" test "$(calls)" = 1
check "thought feedback appends only one observation" test "$(observations)" = 1

# Process and structured errors fail softly and retain the step for retry.
reset_state; export GBRAIN_EXIT=7
run_step "$message"
check "process error appends no observation" test "$(observations)" = 0
unset GBRAIN_EXIT; export GBRAIN_RESPONSE='{"error":"unavailable"}'
run_step "$message"
check "failed step retries instead of becoming seen" test "$(calls)" = 2
export GBRAIN_RESPONSE='{"protocol_version":1,"facts":[{"text":"Recovered."}]}'
run_step "$message"
check "retry can recover" test "$(calls)" = 3
check "recovery appends context once" test "$(observations)" = 1

# A failed trajectory append is not marked handled, so redelivery can restore
# the otherwise valid context instead of losing it permanently.
reset_state; export GBRAIN_RESPONSE='{"protocol_version":1,"facts":[{"text":"Append retry."}]}' TRAJ_EXIT=8
run_step "$message"
check "append failure leaves no observation" test "$(observations)" = 0
unset TRAJ_EXIT
run_step "$message"
check "append failure retries the GBrain result" test "$(calls)" = 2
check "append retry eventually records context" test "$(observations)" = 1

check "state contains no query or retrieved content" bash -c '! grep -R -q "What does\|Recovered\|Context" "$1"' _ "$GBRAIN_RECALL_STATE_DIR"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
