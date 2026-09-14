#!/bin/bash
# start_antfarm.sh - launcher for Dwarf Fortress + the Antfarm companion
#
# Option 5 brings the whole stream up at once: the game in one window and the
# dashboard (with the Twitch bridge, if configured) in another.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR" || exit 1

PY="$BASE_DIR/.venv/bin/python"
STATE="$BASE_DIR/game/antfarm_state.json"

# ---------------------------------------------------------------- #
# terminal detection                                               #
# ---------------------------------------------------------------- #
# Set ANTFARM_TERMINAL to force one. Each emulator spells "run this command
# with this title" differently, hence the per-terminal argv rather than a
# single template.
detect_terminal() {
    if [ -n "$ANTFARM_TERMINAL" ] && command -v "$ANTFARM_TERMINAL" >/dev/null 2>&1; then
        echo "$ANTFARM_TERMINAL"; return
    fi
    for t in kitty wezterm alacritty foot konsole gnome-terminal xfce4-terminal terminator xterm; do
        command -v "$t" >/dev/null 2>&1 && { echo "$t"; return; }
    done
    echo ""
}

# Quote a string for safe inclusion in a single-quoted shell word.
# A path like /home/user/o'malley/df breaks `cd '$BASE_DIR'` outright, and the
# commands below are assembled into a string for `bash -lc`.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# spawn_term <title> <command...>
spawn_term() {
    local title="$1"; shift
    local term; term=$(detect_terminal)
    [ -z "$term" ] && return 1

    case "$term" in
        kitty)           setsid kitty --title "$title" -- bash -lc "$*" >/dev/null 2>&1 & ;;
        wezterm)         setsid wezterm start --class "$title" -- bash -lc "$*" >/dev/null 2>&1 & ;;
        alacritty)       setsid alacritty -t "$title" -e bash -lc "$*" >/dev/null 2>&1 & ;;
        foot)            setsid foot -T "$title" bash -lc "$*" >/dev/null 2>&1 & ;;
        konsole)         setsid konsole -p "tabtitle=$title" -e bash -lc "$*" >/dev/null 2>&1 & ;;
        gnome-terminal)  setsid gnome-terminal --title="$title" -- bash -lc "$*" >/dev/null 2>&1 & ;;
        xfce4-terminal)  setsid xfce4-terminal --title="$title" -x bash -lc "$*" >/dev/null 2>&1 & ;;
        terminator)      setsid terminator -T "$title" -x bash -lc "$*" >/dev/null 2>&1 & ;;
        xterm)           setsid xterm -T "$title" -e bash -lc "$*" >/dev/null 2>&1 & ;;
        *)               return 1 ;;
    esac
    return 0
}

# -x matches the process NAME; `pgrep -f libs/Dwarf_Fortress` also matches this
# script's own command line and always reports "running".
df_running() { pgrep -x Dwarf_Fortress >/dev/null 2>&1; }

# ---------------------------------------------------------------- #
# actions                                                          #
# ---------------------------------------------------------------- #
launch_everything() {
    local term; term=$(detect_terminal)
    if [ -z "$term" ]; then
        echo "No supported terminal emulator found."
        echo "Install one of: kitty, wezterm, alacritty, foot, konsole, gnome-terminal, xterm"
        echo "or set ANTFARM_TERMINAL=<your terminal>."
        echo
        echo "Falling back: start the game here, then run the dashboard yourself with"
        echo "  $PY -m antfarm.tui"
        sleep 2
        cd game && exec ./dfhack
    fi
    echo "Using terminal: $term"

    if df_running; then
        echo "Dwarf Fortress is already running - not starting a second copy."
    else
        echo "  -> window 1: Dwarf Fortress + DFHack"
        rm -f "$STATE"
        # autolabor logs every dwarf every cycle (~45k lines/hour), so start
        # each session with empty logs rather than letting them grow forever.
        : > "$BASE_DIR/game/stderr.log" 2>/dev/null
        : > "$BASE_DIR/game/stdout.log" 2>/dev/null
        spawn_term "Dwarf Fortress" "cd $(shq "$BASE_DIR/game") && ./dfhack; echo; echo '[DF exited - press enter to close]'; read"
    fi

    # The dashboard tolerates the game not being up yet, but waiting for the
    # bridge means it opens straight onto live data instead of the waiting HUD.
    echo -n "  -> waiting for the fortress bridge"
    for _ in $(seq 1 40); do
        [ -f "$STATE" ] && break
        echo -n "."; sleep 1
    done
    echo
    if [ -f "$STATE" ]; then
        echo "     bridge is up."
    else
        echo "     no bridge yet (load a save in DF); the dashboard will pick it up automatically."
    fi

    echo "  -> window 2: Antfarm dashboard"
    spawn_term "Antfarm Dashboard" "cd $(shq "$BASE_DIR") && $(shq "$PY") -m antfarm.tui; echo; echo '[dashboard exited - press enter to close]'; read"

    echo
    echo "Everything is up. Load or continue a fort in the Dwarf Fortress window."
    if [ -f "$BASE_DIR/config/twitch.json" ] || [ -n "$TWITCH_CHANNEL" ]; then
        echo "Twitch: configured - the bridge runs inside the dashboard."
    else
        echo "Twitch: not configured (see config/twitch.example.json) - dashboard only."
    fi
}

show_status() {
    echo "--- Antfarm status ---"
    if df_running; then echo "Dwarf Fortress: running"; else echo "Dwarf Fortress: not running"; fi
    if [ -f "$STATE" ]; then
        echo "IPC state file: present (updated $(date -r "$STATE" '+%H:%M:%S'))"
        # The path is passed in rather than assumed: this function is safe to
        # call from anywhere, not just with the repo root as the working
        # directory.
        "$PY" - "$STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
st = s.get("fortress_stats", {})
print(f"  map loaded : {s.get('map_loaded')}")
print(f"  population : {st.get('pop')}   year {st.get('year')} {st.get('season')}   "
      f"{st.get('fps')} FPS{'  [PAUSED]' if st.get('paused') else ''}")
print(f"  camera mode: {s.get('mode')}   following unit {s.get('follow_id')}")
u = s.get("unit_data")
if u:
    print(f"  on camera  : {u.get('name')} - {u.get('profession')}, {u.get('current_job')}")
b = s.get("build")
if not b:
    print("  build      : no plan running")
elif not b.get("anchored"):
    print("  build      : not anchored")
    print("               run 'antfarm_blueprint autostart' in the DFHack console to")
    print("               have it pick a site, or 'antfarm_blueprint here' at the cursor")
else:
    auto = " [auto]" if b.get("auto") else ""
    gate = "ready" if b.get("ready") else b.get("status", "")
    print(f"  build      : step {b.get('step')}/{b.get('total')} {b.get('label')}{auto} - {gate}")
    print(f"               {b.get('note')}")
    if b.get("stalled"):
        print(f"  STALLED    : {b.get('stall_reason')}")
    for warn in b.get("warnings") or []:
        print(f"  warning    : {warn}")
u = s.get("ui")
if u:
    print(f"  screen     : {u.get('screen')}"
          + ("  [PAUSED]" if u.get("paused") else ""))
    print(f"  watchdog   : {u.get('popups_dismissed', 0)} popup(s), "
          f"{u.get('screens_dismissed', 0)} screen(s) dismissed, "
          f"{u.get('failures', 0)} failure(s)")
    if u.get("pending_popups"):
        print(f"  BLOCKED    : {u['pending_popups']} popup(s) waiting")
PY
    else
        echo "IPC state file: absent - is a save loaded?"
        echo "  The bridge starts from dfhack-config/init/onMapLoad.init;"
        echo "  from the DFHack console you can also run: antfarm_server status"
    fi
    if [ -f config/twitch.json ] || [ -n "$TWITCH_CHANNEL" ]; then
        echo "Twitch: configured"
    else
        echo "Twitch: not configured (see config/twitch.example.json)"
    fi
}

# The PyLNP launcher used to list these behind a Tk GUI. It has been removed --
# it rewrote the DFHack and graphics init files and kept undoing the crash fixes
# in AGENTS.md 6.2 -- so the launchers are listed here instead.
show_utilities() {
    echo "--- Bundled utilities ---"
    local i=0 names=() paths=()
    for f in "$BASE_DIR"/tools/*.sh; do
        [ -x "$f" ] || continue
        i=$((i + 1))
        names+=("$(basename "$f" .sh)")
        paths+=("$f")
        echo "  $i) $(basename "$f" .sh)"
    done
    [ "$i" -eq 0 ] && { echo "  none found in tools/"; return; }
    echo "  0) back"
    read -r -p "Select [0-$i]: " pick
    case "$pick" in
        ''|0) return ;;
        *[!0-9]*) echo "Not a number."; return ;;
    esac
    [ "$pick" -ge 1 ] && [ "$pick" -le "$i" ] || { echo "Out of range."; return; }
    echo "Starting ${names[$((pick - 1))]}..."
    setsid "${paths[$((pick - 1))]}" >/dev/null 2>&1 &
}

echo "=========================================================="
echo "          Dwarf Fortress + Antfarm Companion              "
echo "=========================================================="
echo "  1) Launch EVERYTHING (game + dashboard, own windows)"
echo "  2) Dwarf Fortress + DFHack only (this window)"
echo "  3) Antfarm dashboard only (this window)"
echo "  4) Twitch chat bridge only, no dashboard (this window)"
echo "  5) Status"
echo "  6) Utilities (Dwarf Therapist, Legends Browser, SoundSense...)"
echo "=========================================================="
read -r -p "Select option [1-6] (default: 1): " choice
choice=${choice:-1}

case "$choice" in
    2) cd game || exit 1; exec ./dfhack ;;
    3) exec "$PY" -m antfarm.tui ;;
    4) exec "$PY" -m antfarm.twitch ;;
    5) show_status ;;
    6) show_utilities ;;
    *) launch_everything ;;
esac
