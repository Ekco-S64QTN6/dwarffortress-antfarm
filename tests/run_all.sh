#!/bin/bash
# Run every Antfarm check that does not need Dwarf Fortress running.
#
# NEVER point these at the live game directory: they write a fake state file and
# send commands, and a running fortress will execute them (AGENTS.md 6.5 records
# a test nickname landing on a real dwarf). The Python suite sets ANTFARM_DF_DIR
# to a scratch directory for exactly this reason.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "Lua syntax"
for f in game/hack/scripts/antfarm_*.lua; do
    if luac -p "$f"; then echo "  ok    $f"; else echo "  FAIL  $f"; fail=1; fi
done

step "Python syntax"
if .venv/bin/python -m compileall -q antfarm/ tests/; then echo "  ok"; else fail=1; fi

step "Shell syntax"
for f in start_antfarm.sh tools/*.sh; do
    if bash -n "$f" 2>/dev/null; then echo "  ok    $f"; else echo "  FAIL  $f"; fail=1; fi
done

step "Lua unit tests"
for t in tests/test_*.lua; do
    lua "$t" || fail=1
done

step "Python unit tests"
.venv/bin/python -m tests.test_engine || fail=1

printf '\n'
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$fail"
