# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**[AGENTS.md](AGENTS.md) is the deep reference and takes precedence over this file.** It is a 600-line
record of bugs that were expensive to find — DFHack API traps, game-stability settings, worldgen
constraints, and field names verified against a live fort. Section 6 in particular is not optional
reading before touching any Lua. This file is the orientation; that one is the map of the minefield.

---

## Commands

```bash
./tests/run_all.sh                  # everything that does not need the game: syntax + all suites
./start_antfarm.sh                  # menu: game / dashboard / chat bridge / status / utilities

lua tests/test_antfarm_ui.lua       # one Lua suite
.venv/bin/python -m tests.test_engine                       # one Python suite
.venv/bin/python -m unittest tests.test_engine -k probe     # filter within a suite
.venv/bin/python -m unittest tests.test_engine.Claims.test_release_frees_the_viewer

luac -p game/hack/scripts/antfarm_ui.lua                    # Lua syntax only
.venv/bin/python -m compileall -q antfarm/                  # Python syntax only
```

The venv carries only `textual` and `rich` — no test framework, no linter. Tests are plain
`unittest` and hand-rolled Lua assertions. Keep it that way; the stream box should not need more.

### Driving a live fortress

Dwarf Fortress cannot run headlessly, but it can be driven non-interactively, and this is by far the
fastest way to verify anything touching DFHack:

```bash
cd game && nohup ./dfhack &                  # launch
./dfhack-run antfarm_ui status               # any DFHack command, against the running game
./dfhack-run lua 'print(dfhack.gui.getCurFocus(true))'
./df -gen 1 RANDOM TOLKIEN_EPIC_MEDIUM       # generate a world, no keyboard needed
```

Script `print()` output lands in `game/stderr.log`, **not** the terminal. Note that
`./dfhack-run` prints ANSI escapes; strip them before parsing.

**Never point the test suites at `game/`.** They write a fake state file and send commands, and a
running fortress will execute them. `tests/test_engine.py` and `test_wire.py` set `ANTFARM_DF_DIR`
to a scratch directory for exactly this reason.

---

## Architecture

Two processes that share nothing but a directory of files.

```
game/  (Dwarf Fortress + DFHack, Lua)          antfarm/  (Python)
  antfarm_server.lua   the bridge   ──state──►   client.py    transport
  antfarm_ui.lua       watchdog     ◄──cmds───   engine.py    Director AI
  antfarm_blueprint.lua  build              tui.py / twitch.py
  antfarm_embark.lua   site picker
  antfarm_lever.lua    lockdown
```

**Transport** (`antfarm/client.py` ⟷ `antfarm_server.lua`): `game/antfarm_state.json` is rewritten
atomically every 200ms; commands go the other way as **one file per command** in
`game/antfarm_cmd/`, tmp-then-renamed, drained in lexical filename order. A single shared command
file cannot work — the once-a-second heartbeat overwrites anything queued within one tick. A TCP
path exists but files are the supported default (AGENTS.md 6.1.7: the luasocket `accept()` path has
segfaulted DF).

### Who decides what

This split is the thing worth internalising, and it has moved:

- **Lua owns anything needing frame timing or the UI.** Popup and viewscreen dismissal, pause
  classification, auto-unpause, camera restore, build gating. It has to: `pause_state = false` does
  nothing while a popup is queued, so unpausing *requires* clearing the popup first, from inside the
  game.
- **Python owns scoring and presentation.** Interest scores, camera target choice, the dashboard,
  chat. It reads state and sends verbs; it does not reason about screens.
- **Standing fortress automation is neither** — it lives in
  `game/dfhack-config/init/onMapLoad.init`, declarative, applied by DFHack on every load.
  `AntfarmEngine.execute_initial_payloads()` is only for things that depend on this being a
  *streamed* session. Duplicating init commands in Python double-registers the `repeat` jobs.

`antfarm_server.lua` drives the other Lua scripts via `reqscript` (module mode — it does not
re-run their CLI) and folds their reports into the state file. Adding a subsystem means: a module
with `tick()`/`report()`, a `reqscript` in the server's poll, and a key in `collect_state()`.

### The watchdog (`antfarm_ui.lua`)

The single most load-bearing component, because the thing that stops an unattended fort is a dialog
box. Much of it is ported from [df-ai](https://github.com/BenLubar/df-ai) (`pause.cpp`, `ai.cpp`) —
read AGENTS.md 6.7.2 before reinventing any of it. Two mechanisms, because DF has two: popups in
`world.status.popups` are drawn *inside* the map view (so a screen-type check never finds them) and
clear with `CLOSE_MEGA_ANNOUNCEMENT`; real viewscreens get an escalating `LEAVESCREEN` ladder.

Three invariants:

- **Never send a key to a parentless screen.** `LEAVESCREEN` on `viewscreen_dwarfmodest` opens the
  abandon menu; `screen.dismiss` on a root screen exits DF immediately.
- **Never dismiss the world-setup screens** (title, load, embark, worldgen) — the operator is using
  them. Viewscreen dismissal is additionally gated on a client actually driving the fort.
- **Verify the screen before every keystroke.** `start_driver()` is the coroutine primitive for
  multi-step UI (a port of df-ai's `ExclusiveCallback`); blind keystrokes corrupt forts.

### The guided build (`antfarm_blueprint.lua`)

A 22-step state machine over DFHack's Dreamfort blueprints, persisted to `game/antfarm_plan.json`.
Each step declares a gate (`dig` / `build` / `none`) scoped **to its own level, not the whole fort** —
gating on the whole excavation starved a live fort of booze (AGENTS.md 6.9). Dreamfort's underground
levels are not independently placeable; only surface, farming and industry are free choices.

Steps are verified against quickfort's own output, because quickfort reports success having touched
nothing. A step that does no work is retried and then recorded as a warning rather than silently
skipped. `docs/fortress-build.md` has the full design.

---

## Testing without the game

`tests/df_stub.lua` is a fake `df`/`dfhack`: a viewscreen stack you can push screens onto, a popup
queue, an announcement log with `d_init` flags, a sparse map you can write geology columns into, and
a `gui.simulateInput` that records every key. That is what makes it possible to assert *which key*
the watchdog pressed at a cavern popup. **Extend the stub rather than reaching for a mock.**

The stub deliberately reproduces three real failure shapes, because each one was a bug the tests
originally missed (AGENTS.md 6.7.3):

- `w.async_keys = true` — keys are **queued**, applied on a later frame. Code that checks whether a
  screen closed in the same call reads the pre-keystroke screen.
- `region_map[x][y]` **raises**, as it does in DF. The y index is `region_map[x]:_displace(y)`.
- `utils.listpairs(nil)` **errors**, so a wrong field name fails a test instead of only failing live.

`tests/test_wire.py` generates command files with the real Python client and parses them with the
real Lua reader. Add a case there for any new command verb — both halves must agree, and they have
silently disagreed before (a stripped trailing space made every nickname *clear* a no-op).

---

## Things that will bite

- **DF vectors are 0-indexed.** `ipairs()` skips element 0. Use `for i = 0, #vec - 1`.
- **`dfhack.timeout` has no real-time unit.** Only `frames`, `ticks`, `days`, `months`, `years`.
  Use **`frames`**, not `ticks`, for anything that must run while paused — the bridge, auto-unpause
  and the dashboard all must. Gate the actual work on `dfhack.getTickCount()` for a steady cadence.
- **Prefer `dfhack.units.*` over raw flag access.** `unit.flags1.dead` does not exist in this build
  and raised from inside the state serialiser, silently killing the whole bridge.
- **`pgrep -f` matches its own command line.** It has produced false "it's running" readings here
  more than once. Match the process name, or the interpreter's argv.
- **Raws are CP437**, not UTF-8. Read and write `game/data/init/*` and `game/raw/*` with that
  encoding or accented text is corrupted.
- **`game/data/init/` settings are load-bearing for stability.** `[TEMPERATURE:YES]` and
  `[PRINT_MODE:2D]` are not preferences — changing either crashes or hangs the game. AGENTS.md 6.2
  has the reasoning; verify before trusting any claim there, including that one.

`config/` and `state/` hold operator data and are gitignored; `antfarm/` is code only.
