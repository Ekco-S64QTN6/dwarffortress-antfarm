#!/usr/bin/env bash
# Safe, deterministic selection of Dwarf Fortress save folders.
#
# Output format from antfarm_resolve_save: "<kind>|<region>" where kind is
# "fort" or "world". An empty successful result means there are no saved
# worlds. Return code 2 means the selection is ambiguous or invalid.
#
# ANTFARM_REGION selects one save directory explicitly. It is deliberately
# restricted to a single safe path component; it is never evaluated as a path
# supplied by the user.

antfarm_list_saved_regions() {
    local save_root="$1"
    local directory region

    [ -d "$save_root" ] || return 0
    for directory in "$save_root"/*/; do
        [ -d "$directory" ] || continue
        region="$(basename "$directory")"
        [ "$region" = "current" ] && continue
        [[ "$region" =~ ^[A-Za-z0-9_-]+$ ]] || continue

        if [ -f "$directory/world.sav" ]; then
            printf 'fort|%s\n' "$region"
        elif [ -f "$directory/world.dat" ]; then
            printf 'world|%s\n' "$region"
        fi
    done
}

antfarm_resolve_save() {
    local save_root="$1"
    local region directory candidate
    local -a candidates=()

    if [ -n "${ANTFARM_REGION:-}" ]; then
        region="$ANTFARM_REGION"
        if [[ ! "$region" =~ ^[A-Za-z0-9_-]+$ ]] || [ "$region" = "current" ]; then
            printf 'Invalid ANTFARM_REGION value: %s\n' "$region" >&2
            printf 'Use the name of one save folder (for example region2).\n' >&2
            return 2
        fi
        directory="$save_root/$region"
        if [ -f "$directory/world.sav" ]; then
            printf 'fort|%s\n' "$region"
            return 0
        elif [ -f "$directory/world.dat" ]; then
            while IFS= read -r candidate; do
                [ -n "$candidate" ] && candidates+=("$candidate")
            done < <(antfarm_list_saved_regions "$save_root")
            if [ "${#candidates[@]}" -gt 1 ]; then
                printf 'ANTFARM_REGION=%s is a generated world, but multiple worlds are on disk.\n' "$region" >&2
                printf 'The launcher cannot select an entry in DFHack title-screen start_savegames yet.\n' >&2
                printf 'Choose the generated world manually from Start Playing, or select a fortress with ANTFARM_REGION.\n' >&2
                return 2
            fi
            printf 'world|%s\n' "$region"
            return 0
        fi
        printf 'ANTFARM_REGION=%s does not contain world.sav or world.dat under %s\n' \
            "$region" "$save_root" >&2
        return 2
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] && candidates+=("$candidate")
    done < <(antfarm_list_saved_regions "$save_root")

    case "${#candidates[@]}" in
        0)
            printf ''
            return 0
            ;;
        1)
            printf '%s\n' "${candidates[0]}"
            return 0
            ;;
        *)
            printf 'Multiple saved worlds/fortresses found under %s:' "$save_root" >&2
            printf ' %s' "${candidates[@]}" >&2
            printf '\nSet ANTFARM_REGION=<save-folder> to select an existing fortress explicitly.\n' >&2
            return 2
            ;;
    esac
}
