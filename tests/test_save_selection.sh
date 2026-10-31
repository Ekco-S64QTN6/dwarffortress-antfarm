#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/lib/antfarm_saves.sh
source "$ROOT/tools/lib/antfarm_saves.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
saves="$tmp/save"
mkdir -p "$saves"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [ "$expected" = "$actual" ] || fail "$label: expected [$expected], got [$actual]"
}

# Empty installation; a DF "current" working folder is not a selectable world.
mkdir -p "$saves/current"
assert_eq "" "$(antfarm_resolve_save "$saves")" "empty save root"

# Single world and single fortress keep the one-button path.
mkdir -p "$saves/region1"
: > "$saves/region1/world.dat"
assert_eq "world|region1" "$(antfarm_resolve_save "$saves")" "single world"

rm -rf "$saves/region1"
mkdir -p "$saves/region2"
: > "$saves/region2/world.sav"
assert_eq "fort|region2" "$(antfarm_resolve_save "$saves")" "single fortress"

# An explicit selection is deterministic even with multiple saves.
mkdir -p "$saves/region1"
: > "$saves/region1/world.dat"
assert_eq "fort|region2" "$(ANTFARM_REGION=region2 antfarm_resolve_save "$saves")" "explicit fort"
assert_eq "world|region1" "$(ANTFARM_REGION=region1 antfarm_resolve_save "$saves")" "explicit world"

# With multiple candidates, never depend on glob order or silently pick the
# first fortress ahead of a generated world.
if output="$(antfarm_resolve_save "$saves" 2>&1)"; then
    fail "ambiguous selection unexpectedly succeeded: $output"
fi
[[ "$output" == *"world|region1"* && "$output" == *"fort|region2"* ]] \
    || fail "ambiguity message did not name every candidate: $output"

# Invalid values cannot escape the save root or select arbitrary folders.
for invalid in "../outside" "/tmp" "region2/../../etc" "current" "bad|name"; do
    if output="$(ANTFARM_REGION="$invalid" antfarm_resolve_save "$saves" 2>&1)"; then
        fail "invalid region [$invalid] unexpectedly succeeded: $output"
    fi
done
if output="$(ANTFARM_REGION=region99 antfarm_resolve_save "$saves" 2>&1)"; then
    fail "missing explicit region unexpectedly succeeded: $output"
fi

# Directories without a DF world marker and the generated current folder are
# ignored even when they sort before the actual region names.
mkdir -p "$saves/backup" "$saves/current"
: > "$saves/backup/README.txt"
assert_eq "fort|region2" "$(ANTFARM_REGION=region2 antfarm_resolve_save "$saves")" "ignore unrelated folders"

echo "Save selection tests passed."
