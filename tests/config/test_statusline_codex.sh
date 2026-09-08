#!/bin/bash
# Codex-segment tests for statusline.sh
#
# The statusline gains a Codex segment beside the Claude meters, read from the
# fleet's Codex rate-limit snapshot (infra/.state/codex-usage.json, written by
# bareclaude's codex-usage-read.sh - ENG-2314). These tests feed fixture files
# through BARECLAUDE_ROOT and pin:
#
#   - one bar per window of the `codex` limit, shortest window first, labelled
#     from the window length (300 -> 5h, 10080 -> wk, else Nm/Nh/Nd)
#   - the longest window's burn ratio, only when the reader computed one
#   - fail-closed rendering ("codex --") for a missing file, a status other
#     than ok, an unreadable fetched_at, or a snapshot older than 2h - and
#     never a stale percentage
#   - no segment at all when the fleet state directory itself is absent (a
#     synced laptop with no BareClaude tree gets no dead "codex --")
#   - other limit ids in the file (codex_bengalfox) never leak into the line
#
# The statusline must never call `codex` itself; these tests put a `codex`
# stub on PATH that fails loudly so any such call breaks the run.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Resolve paths relative to this file, not the caller's cwd (tests/test.sh runs
# it from tests/), matching the sibling statusline suites.
cd "$(dirname "$0")"

TEST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/statusline_codex_test.XXXXXX")"

STATUSLINE_PATH="$(cd ../../system-configs/.claude && pwd)/statusline.sh"

STDIN_JSON='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/claude-config"},"output_style":{"name":"Concise"},"version":"2.0.44","context_window":{"used_percentage":31}}'

print_pass() { echo -e "${GREEN}✓${NC} $1"; }
print_fail() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }

cleanup() { rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# A `codex` on PATH that must never be reached: the segment reads the state
# file only. If the statusline ever shells out to codex, the stub writes a
# marker the final assertion checks for.
STUB_BIN="$TEST_TEMP_DIR/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/bash\ntouch "%s/codex_was_called"\nexit 1\n' "$TEST_TEMP_DIR" > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/codex"

# ISO8601 UTC timestamp N seconds from now, in the reader's format (Z suffix,
# no fractional seconds). Negative N gives a timestamp in the past.
iso_in() {
    date -u -r $(( $(date -u +%s) + $1 )) +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d "@$(( $(date -u +%s) + $1 ))" +"%Y-%m-%dT%H:%M:%SZ"
}

# A fresh plan-mode Claude usage cache, so the Claude segment renders
# deterministically and the script never reaches for the Keychain or the
# network during a test.
claude_cache() {
    cat <<EOC
{
  "extra_usage": { "spend_limit_reached": false },
  "spend": {
    "used":  { "amount_minor": 75160, "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": 200000, "currency": "USD", "exponent": 2 },
    "percent": 38, "enabled": true
  },
  "limits": [
    { "kind": "session",       "percent": 45, "resets_at": "$(iso_in 5400 | sed 's/Z$/.000000+00:00/')" },
    { "kind": "weekly_all",    "percent": 62, "resets_at": "$(iso_in 131400 | sed 's/Z$/.000000+00:00/')" },
    { "kind": "weekly_scoped", "percent": 25, "resets_at": "$(iso_in 131400 | sed 's/Z$/.000000+00:00/')" }
  ]
}
EOC
}

# window <minutes> <used_percent> <burn_ratio|null>
window() {
    printf '{"minutes":%s,"used_percent":%s,"resets_at":"%s","burn_ratio":%s}' \
        "$1" "$2" "$(iso_in $(( $1 * 60 )))" "$3"
}

# fixture <status> <fetched_at> <codex-windows-json-array>
# Always carries a second limit id (codex_bengalfox) with a loud 77% so a leak
# from the wrong limit is unmistakable.
fixture() {
    cat <<EOC
{
  "fetched_at": "$2",
  "last_ok_at": "$2",
  "status": "$1",
  "reason": null,
  "plan_type": "pro",
  "limits": {
    "codex": { "windows": $3 },
    "codex_bengalfox": { "windows": [$(window 300 77 null), $(window 10080 77 null)] }
  },
  "credits": { "hasCredits": false, "unlimited": false, "balance": "0" },
  "spend_control_reached": false
}
EOC
}

# render_raw [fixture-json] -> statusline with ANSI intact.
# No argument = state directory present but no state file (the missing-file
# case). NO_STATE_DIR=1 leaves out the infra/.state directory altogether.
render_raw() {
    local root="$TEST_TEMP_DIR/root_$RANDOM$RANDOM"
    local h="$TEST_TEMP_DIR/home_$RANDOM$RANDOM"
    mkdir -p "$h/.claude"
    if [[ "${NO_STATE_DIR:-0}" == "1" ]]; then
        mkdir -p "$root"
    else
        mkdir -p "$root/infra/.state"
    fi
    claude_cache > "$h/.claude/.usage_cache.json"
    if [[ $# -gt 0 ]]; then
        printf '%s' "$1" > "$root/infra/.state/codex-usage.json"
    fi
    printf '%s' "$STDIN_JSON" \
        | HOME="$h" BARECLAUDE_ROOT="$root" PATH="$STUB_BIN:$PATH" bash "$STATUSLINE_PATH" 2>/dev/null
}

# render [fixture-json] -> plain (ANSI-stripped) statusline
render() {
    render_raw "$@" | sed $'s/\033\\[[0-9;]*m//g'
}

# Just the codex segment (everything from "codex " to end of line), so
# assertions about "burn" or a percentage can't be satisfied by the Claude
# meters sitting earlier on the same line.
codex_part() {
    printf '%s' "$1" | sed -n 's/.*• codex /codex /p'
}

assert_eq() {
    local got="$1" want="$2" name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$got" == "$want" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (want '$want', got '$got')"
    fi
}

assert_contains() {
    local out="$1" needle="$2" name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (expected '$needle' in: $out)"
    fi
}

assert_missing() {
    local out="$1" needle="$2" name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (should not contain '$needle' in: $out)"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "$name"
    fi
}

echo "======================================="
echo "Statusline Codex Segment Tests"
echo "======================================="
echo

print_info "Weekly-only limit (the Mini's live shape): one bar, wk label, burn"
OUT=$(render "$(fixture ok "$(iso_in -600)" "[$(window 10080 2 0.2)]")")
assert_eq "$(codex_part "$OUT")" "codex ░░░░░ 2% wk · burn 0.2x" "weekly-only renders one bar with burn"
assert_contains "$OUT" "all ▓▓▓░░ 62%" "Claude meters still render alongside"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$OUT" | grep -qE 'all [^•]*• codex '; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "codex segment follows the Claude segment"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "codex segment follows the Claude segment (got: $OUT)"
fi
assert_missing "$OUT" "77%" "other limit ids (codex_bengalfox) do not leak"

echo
print_info "5h + weekly windows: shortest first regardless of file order"
OUT=$(render "$(fixture ok "$(iso_in -600)" "[$(window 10080 62 1.2), $(window 300 30 null)]")")
assert_eq "$(codex_part "$OUT")" "codex ▓▓░░░ 30% 5h · ▓▓▓░░ 62% wk · burn 1.2x" "5h bar precedes wk bar; burn is the weekly window's"

echo
print_info "Burn is omitted, not dashed, when the reader has none"
OUT=$(render "$(fixture ok "$(iso_in -600)" "[$(window 300 30 null), $(window 10080 62 null)]")")
assert_eq "$(codex_part "$OUT")" "codex ▓▓░░░ 30% 5h · ▓▓▓░░ 62% wk" "no burn slot without a ratio"

echo
print_info "Shorter window's burn ratio never leaks past a null longest window"
OUT=$(render "$(fixture ok "$(iso_in -600)" "[$(window 300 30 1.7), $(window 10080 62 null)]")")
assert_eq "$(codex_part "$OUT")" "codex ▓▓░░░ 30% 5h · ▓▓▓░░ 62% wk" "5h has a ratio but wk (longest) does not; burn omitted, not 1.7x"

echo
print_info "Glyphs and colours match the Claude meters"
RAW=$(render_raw "$(fixture ok "$(iso_in -600)" "[$(window 300 91 null), $(window 10080 62 1.2)]")")
assert_contains "$RAW" $'\033[31m▓▓▓▓▓ 91%' "91% is a red full bar (heat_color/heat_bar)"
assert_contains "$RAW" $'\033[32m▓▓▓░░ 62%' "62% is a green bar"
assert_contains "$RAW" $'burn \033[33m1.2x' "1.2x burn is yellow (same tier as the Claude burn)"
RAW=$(render_raw "$(fixture ok "$(iso_in -600)" "[$(window 10080 10 0.3)]")")
assert_contains "$RAW" $'burn \033[38;5;39m0.3x' "0.3x burn is blue"
RAW=$(render_raw "$(fixture ok "$(iso_in -600)" "[$(window 10080 80 1.6)]")")
assert_contains "$RAW" $'burn \033[31m1.6x' "1.6x burn is red"
assert_contains "$RAW" $'\033[38;5;208m▓▓▓▓░ 80%' "80% is an orange bar"

echo
print_info "Window labels derive from the window length"
OUT=$(render "$(fixture ok "$(iso_in -600)" "[$(window 30 5 null), $(window 60 15 null), $(window 90 25 null), $(window 720 35 null), $(window 2880 45 null)]")")
assert_eq "$(codex_part "$OUT")" "codex ░░░░░ 5% 30m · ▓░░░░ 15% 1h · ▓░░░░ 25% 90m · ▓▓░░░ 35% 12h · ▓▓░░░ 45% 2d" "Nm / Nh / Nd labels"

echo
print_info "Fractional percentages truncate like the Claude meters"
OUT=$(render "$(fixture ok "$(iso_in -600)" "[$(window 10080 2.7 null)]")")
assert_eq "$(codex_part "$OUT")" "codex ░░░░░ 2% wk" "2.7 renders as 2%"

echo
print_info "Stale snapshot (fetched 3h ago) renders codex -- and never its numbers"
OUT=$(render "$(fixture ok "$(iso_in -10800)" "[$(window 300 37 null), $(window 10080 53 1.4)]")")
assert_eq "$(codex_part "$OUT")" "codex --" "stale file is dashed"
assert_missing "$OUT" "37%" "stale 5h percentage not shown"
assert_missing "$OUT" "53%" "stale weekly percentage not shown"
assert_missing "$OUT" "1.4x" "stale burn not shown"

echo
print_info "Future fetched_at (negative age) renders codex -- and never its numbers"
OUT=$(render "$(fixture ok "$(iso_in 600)" "[$(window 300 37 null), $(window 10080 53 1.4)]")")
assert_eq "$(codex_part "$OUT")" "codex --" "future snapshot is dashed"
assert_missing "$OUT" "37%" "future 5h percentage not shown"
assert_missing "$OUT" "53%" "future weekly percentage not shown"
assert_missing "$OUT" "1.4x" "future burn not shown"

echo
print_info "Snapshot inside the 2h window is still live"
OUT=$(render "$(fixture ok "$(iso_in -7000)" "[$(window 10080 53 null)]")")
assert_eq "$(codex_part "$OUT")" "codex ▓▓▓░░ 53% wk" "1h56m old is fresh enough"

echo
print_info "Missing state file (directory present) renders codex --"
OUT=$(render)
assert_eq "$(codex_part "$OUT")" "codex --" "no file, dashed segment"
assert_contains "$OUT" "all ▓▓▓░░ 62%" "Claude meters unaffected by a missing Codex file"

echo
print_info "Missing state directory renders no codex segment at all"
OUT=$(NO_STATE_DIR=1 render)
# Matched on the extracted segment, not the whole line: the git branch name
# in the line may legitimately contain the word "codex".
assert_eq "$(codex_part "$OUT")" "" "no fleet tree, no segment (not even codex --)"
assert_missing "$OUT" "• codex" "no codex separator on the line"
assert_contains "$OUT" "all ▓▓▓░░ 62%" "Claude meters unaffected"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$OUT" == *"5h ▓▓░░░ 45%" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "line ends at the Claude meters with no trailing separator"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "line ends at the Claude meters with no trailing separator (got: $OUT)"
fi

echo
print_info "status != ok renders codex -- even if limits are present"
OUT=$(render "$(fixture unavailable "$(iso_in -60)" "[$(window 10080 53 1.4)]")")
assert_eq "$(codex_part "$OUT")" "codex --" "unavailable is dashed"
assert_missing "$OUT" "53%" "percentage from an unavailable payload not shown"

echo
print_info "Unreadable fetched_at renders codex --"
OUT=$(render "$(fixture ok "not-a-timestamp" "[$(window 10080 53 null)]")")
assert_eq "$(codex_part "$OUT")" "codex --" "unparsable freshness is treated as stale"
assert_missing "$OUT" "53%" "percentage behind an unreadable timestamp not shown"

echo
print_info "No windows under the codex limit renders codex --"
OUT=$(render "$(fixture ok "$(iso_in -60)" "[]")")
assert_eq "$(codex_part "$OUT")" "codex --" "empty window list is dashed"
assert_missing "$OUT" "77%" "does not fall back to another limit id"

echo
print_info "Malformed JSON renders codex --"
OUT=$(render '{"status":"ok","fetched_at":')
assert_eq "$(codex_part "$OUT")" "codex --" "unparsable file is dashed"

echo
print_info "The statusline never invokes codex itself"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -e "$TEST_TEMP_DIR/codex_was_called" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "codex binary was called during rendering"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "codex binary never called (file read only)"
fi

echo
echo "======================================="
echo "Codex Segment Test Summary"
echo "======================================="
echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} All statusline codex segment tests passed!"
    exit 0
else
    echo -e "${RED}✗${NC} Some statusline codex segment tests failed!"
    exit 1
fi
