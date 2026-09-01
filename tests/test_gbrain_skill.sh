#!/usr/bin/env bash
# test_gbrain_skill.sh — bundled GBrain skill discovery and safety metadata.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SKILL="$REPO/skills/gbrain/SKILL.md"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

list=$(SKILLS_DIR="$REPO/skills" SKILLSRC=/dev/null NO_COLOR=1 "$REPO/bin/skills" list --all 2>&1)
if printf '%s\n' "$list" | grep -q '^[[:space:]]*gbrain[[:space:]]'; then
    ok "bundled skill is discoverable"
else
    bad "bundled skill is discoverable" "$list"
fi

requires=$(SKILLS_DIR="$REPO/skills" SKILLSRC=/dev/null NO_COLOR=1 \
    "$REPO/bin/skills" show gbrain --requires 2>&1)
if printf '%s\n' "$requires" | grep -q '"gbrain"'; then
    ok "gbrain binary requirement parses"
else
    bad "gbrain binary requirement parses" "$requires"
fi
if printf '%s\n' "$requires" | grep -q '"env"[[:space:]]*:[[:space:]]*\[\]'; then
    ok "skill declares no credential environment requirement"
else
    bad "skill declares no credential environment requirement" "$requires"
fi

if grep -Eqi '(https?://|/(Users|home)/|api[_-]?key|access[_-]?token|bearer[[:space:]]+[A-Za-z0-9])' "$SKILL"; then
    bad "skill embeds no secret-bearing or local configuration"
else
    ok "skill embeds no secret-bearing or local configuration"
fi

if grep -q 'gbrain engine status --json' "$SKILL" \
    && grep -q 'gbrain call recall' "$SKILL" \
    && grep -q 'gbrain remember .*--provenance .*--visibility private' "$SKILL" \
    && grep -q 'gbrain call extract_facts' "$SKILL"; then
    ok "skill documents the intended read and explicit-write commands"
else
    bad "skill documents the intended read and explicit-write commands"
fi

if grep -q 'Do not autonomously save ordinary thoughts' "$SKILL" \
    && grep -q 'never as executable' "$SKILL" \
    && grep -q 'paid,' "$SKILL" \
    && grep -q 'source_slug' "$SKILL" \
    && grep -q 'session_id' "$SKILL"; then
    ok "skill pins autonomy, injection, cost, and provenance boundaries"
else
    bad "skill pins autonomy, injection, cost, and provenance boundaries"
fi

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
