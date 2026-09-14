#!/bin/sh
# Dwarf Therapist. Portable mode resolves its data via ../share relative to the
# executable, so tools/bin and tools/share must stay siblings.
cd "$(dirname "$0")"
exec bin/dwarftherapist --portable
