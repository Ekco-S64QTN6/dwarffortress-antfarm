# AI Agent Guide for Dwarf Fortress Modding and Automation

This guide explains how autonomous AI agents (such as Antigravity) can safely interact with, modify, and automate configurations and mods in this Dwarf Fortress environment.

---

## 0. Repository Layout

| Path | Role | Safe to edit? |
| --- | --- | --- |
| `antfarm/` | Antfarm Python: IPC client, Director AI, TUI, Twitch bridge, plugins | yes |
| `game/hack/scripts/antfarm_*.lua` | The in-game half of Antfarm | yes -- read section 6.1 first |
| `game/dfhack-config/init/onMapLoad.init` | Standing fortress automation | yes -- preferred over hardcoding commands |
| `game/data/init/` | Game settings | yes -- see 6.2 before touching PRINT_MODE |
| `game/blueprints/library/` | Stock DFHack blueprints incl. Dreamfort | no -- upstream |
| `game/hack/` (except `scripts/antfarm_*.lua`), `tools/` | Upstream DFHack and bundled utilities | no -- upstream |
| `config/`, `state/` | Operator credentials and runtime data. Gitignored | not by agents |
| `docs/` | This project's documentation | yes |

Generated at runtime, never commit: `antfarm_state.json`, `antfarm_cmd/`,
`antfarm_plan.json`, `antfarm.log`, `state/claims.json`, `config/twitch.json`.

**Some paths are load-bearing.** Dwarf Therapist finds its data via `../share`
relative to its own executable, so `tools/bin` and `tools/share` must stay
siblings; `tools/*.sh` reach into `../game` for the game log. `game/` is
otherwise self-contained -- `game/dfhack` cds to its own directory -- so the
only outside references to it are ours, in `antfarm/client.py`,
`start_antfarm.sh`, `tools/legendsbrowser.properties` and the tests.

**PyLNP has been removed.** The Tk launcher, `LNP/`, `core/`, `tkgui/` and
`packaging/` are gone: it rewrote `data/init/init.txt` and the DFHack init files
whenever a graphics pack was switched, which repeatedly undid the crash fixes in
section 6.2, and its generated `dfhack_PyLNP.init` duplicated the housekeeping
`repeat` jobs already in `onMapLoad.init`. Do not reintroduce it. Its two useful
commands (`tweak fast-heat`, `repeat fix/stuckdoors`) now live in
`onMapLoad.init`.

---

## 1. Modding and Editing Protocol

Dwarf Fortress files are flat text files with a declarative structure. To avoid corrupting the game data, agents should adhere to the following protocols:

### 1.1. Syntactic Correctness
*   **Bracket Matching**: Every parameter is declared as `[TAG:VALUE]`. Missing brackets or malformed tags will cause the Dwarf Fortress parser to crash or silently ignore the entire file.
*   **Whitespace Rules**: Raws are indent-agnostic but line-break sensitive. Do not merge raw tags onto a single line if they are separate declarations (e.g., under body templates or attacks).
*   **Unique Headers**: Mod files or appended blocks (like `[WORLD_GEN]` or `[CREATURE:...]`) must have unique identifier names. Reusing an existing name can result in overrides, load errors, or duplicate entries in menus.

### 1.2. Automated Editing with Tools
Agents can leverage the following tools to execute changes:
*   `grep_search`: Locate target objects. Search for `[CREATURE:`, `[ITEM_WEAPON:`, or `[ENTITY:` to find block starts.
*   `replace_file_content`: Ideal for single-block modifications (e.g., editing values under `[CREATURE:DWARF]` or tweaking `d_init.txt`).
*   `multi_replace_file_content`: Best for non-contiguous changes, such as tweaking multiple options (e.g. child caps, saving settings, and invader toggles) within `d_init.txt` at the same time.

---

## 2. Knobs and Settings Tuning for Agents

Agents can programmatically adjust game performance or gameplay variables by executing targeted text replacements:

1.  **FPS Optimization**:
    *   Target File: `game/data/init/d_init.txt`
    *   Change: `[WEATHER:NO]` is safe. `[FPS_CAP]` / `[G_FPS_CAP]` in `init.txt` and a lower `[POPULATION_CAP]` are the other levers.
    *   **Never set `[TEMPERATURE:NO]`** on a save with magma, fire, ice or melt jobs. It is the single biggest FPS win and it segfaults the game within seconds of unpausing -- see 6.2.1.
2.  **Migrant Control**:
    *   Target File: `game/data/init/d_init.txt`
    *   Change: Adjust `[POPULATION_CAP:<N>]` and `[STRICT_POPULATION_CAP:<M>]`.
3.  **World Gen Parameters**:
    *   Target File: `game/data/init/world_gen.txt`
    *   Change: Append a new `[WORLD_GEN]` block with custom dimension and range specifications.

---

## 3. Automation and Fortress Construction

### 3.1. Where automation belongs
Standing fortress automation goes in
`game/dfhack-config/init/onMapLoad.init`: DFHack applies it on every
map load, it is declarative, and the user can edit it without touching code.
**Do not duplicate it in Python.** Re-sending those commands double-registers
the `repeat` jobs and re-enables plugins the init file deliberately leaves off.
`AntfarmEngine.execute_initial_payloads()` is only for things that depend on
this being a streamed session.

Before adding a command, check it exists in *this* build -- DFHack tool names
drift between versions:
```bash
c=autoslab   # example
ls game/hack/plugins/$c.plug.so game/hack/scripts/$c.lua 2>/dev/null
```
`autoslab` does not exist in 0.47, and `autonestbox` is driven with
`autonestbox start`, not `enable`.

### 3.2. Fortress construction
`antfarm_blueprint` drives Dreamfort, the blueprint set shipped in
`game/blueprints/library/dreamfort.csv`. See
[docs/fortress-build.md](docs/fortress-build.md) for the full design.

Two facts constrain any change to it:

1. **Dreamfort's underground levels are not independently placeable.** `/dig_all`
   is anchored once on the industry level and digs everything below at fixed
   offsets (`/industry1 #> /services1 #>4 /guildhall1 #> /suites1 #>
   /apartments1 repeat(down 5)`). Only surface, farming and industry are free
   choices; services/guildhall/suites/apartments are industry −1/−5/−6/−7.
   Surveying them independently places blueprints where nothing was dug.
2. **Blueprint labels are CSV-quoted when they contain commas.** A regex of
   `^#\w+ label\(` silently misses most of them; match `^"?#\w+ label\(`.
   Validate plan changes against the file:
   ```bash
   grep -oE '^"?#(meta|dig|build|place|query|zone) label\([a-z0-9_]+\)' \
     game/blueprints/library/dreamfort.csv
   ```

### 3.3. Bulk raw edits
Dwarf Fortress uses `CP437`. Scripts reading or writing raws must handle that
encoding or special characters in language and description text are corrupted.
Put scratch scripts in the session scratchpad, not the project.

---

## 4. Verification Procedures

There is no way to run Dwarf Fortress headlessly, so verify everything that can
be verified outside it. One command does the lot:

```bash
./tests/run_all.sh
```

It runs Lua syntax on every `antfarm_*.lua`, `compileall` on `antfarm/` and
`tests/`, `bash -n` on the launchers, and the unit suites. Individually:

```bash
for f in game/hack/scripts/antfarm_*.lua; do luac -p "$f"; done
.venv/bin/python -m compileall -q antfarm/
bash -n start_antfarm.sh && sh -n game/dfhack && sh -n game/df
lua tests/test_antfarm_ui.lua
lua tests/test_antfarm_blueprint.lua
.venv/bin/python -m tests.test_engine
```

`tests/df_stub.lua` is a fake `df`/`dfhack`: a viewscreen stack you can push
screens onto, a popup queue, an announcement log with `d_init` flags, a sparse
map you can write columns of geology into, and a `gui.simulateInput` that
records every key. That is what makes it possible to assert *which key* the
watchdog pressed at a cavern popup without launching the game. Extend it rather
than reaching for a mock.

Beyond syntax:

1. **Check every DFHack API call against this build** before trusting it.
   `dfhack.maps.getTileSize` is a Lua helper in `hack/lua/dfhack.lua`, not a
   binary symbol, so `strings hack/libdfhack.so` will not find it. Grep the
   shipped scripts for a working usage instead -- that is ground truth.
2. **Test both sides of a wire format against each other.** Generating command
   files with the real Python client and parsing them with the real Lua reader
   is what caught escaped quotes truncating commands and `\uXXXX` mangling
   accented dwarf names.
3. **Stub `df`/`dfhack` to unit-test pure logic.** The geology survey is tested
   this way against synthetic strata (normal embark, aquifer, no deep rock,
   all water); that is what caught the industry level accepting soil.
4. **Bracket-match** modified raws, and **dry-run worldgen** to confirm custom
   profiles parse.
5. **Read the DFHack console on startup** for raw-loading or script errors.

---

## 5. Antfarm IPC Bridge for Agents

The Antfarm system provides a real-time file-based IPC bridge between DFHack (inside Dwarf Fortress) and external automation scripts. Protocol version 2.

### 5.1. Components
| File | Role |
| --- | --- |
| `game/hack/scripts/antfarm_server.lua` | The bridge. Streams state, drains commands, owns the camera lock. |
| `game/hack/scripts/antfarm_embark.lua` | Ranks every 4x4 rectangle in the world for flatness and picks the embark. |
| `game/hack/scripts/antfarm_legends.lua` | `exportlegends` into `legends/` instead of the game directory. |
| `game/hack/scripts/antfarm_ui.lua` | Modal watchdog: dismisses popups and blocking viewscreens, classifies and clears pauses, answers petitions. Driven by the server's poll. |
| `game/hack/scripts/antfarm_overlay.lua` | `overlay` widget showing mode + current lock inside `dwarfmode`. |
| `game/hack/scripts/antfarm_blueprint.lua` | Surveys geology and drives the Dreamfort build checklist. |
| `game/hack/scripts/antfarm_lever.lua` | Queues high-priority pulls on levers named for defence. |
| `antfarm/client.py` | Python transport. |
| `antfarm/engine.py` | Director AI, interest scoring, knowledge graph, plugin host. |
| `antfarm/twitch.py` | Twitch chat bridge. |

### 5.2. Transport
*   **State** (`game/antfarm_state.json`): written atomically (tmp + rename) every 200ms. Contains `protocol`, `map_loaded`, `mode`, `follow_id`, `fortress_stats` (pop, year, season, fps, paused), `unit_data` (full profile of the focused dwarf incl. skills, attributes, needs, thoughts, health, kills), `citizens` (roster with id, name, nick, claimed, profession, current_job, stress, pos, density), `announcements`, `probe_data`, and `build` (guided-construction progress).

    `build` is refreshed on a 5-second timer, not per frame: its gate check walks every map block on the fort's levels and would otherwise dominate the tick. Anything similarly expensive must be cached the same way.
*   **Commands** (`game/antfarm_cmd/*.json`): **one command per file**, written tmp-then-rename, drained and deleted by the server each tick in lexical filename order. The client names them `%08d-<pid>.json` so the sort is the send order.

    A single shared command file **cannot** work here: the once-a-second heartbeat overwrites any queued command inside one 200ms tick, and chat can burst a dozen commands at once. The legacy single-file `antfarm_cmd.json` is still read for hand-written one-shots.

*   Write command JSON with `ensure_ascii=False`. Dwarf names are full of accented characters; the server decodes `\uXXXX` defensively, but raw UTF-8 is the contract.

### 5.3. Command verbs
| Verb | Effect |
| --- | --- |
| `focus <unit_id>` | Lock the camera onto a unit and centre the viewport. |
| `unfocus` | Release the lock. |
| `ping` | Heartbeat keepalive (any command resets the timer). |
| `mode <name>` | Set `director`/`timed`/`event`/`idle`; only acts on an actual change. |
| `unpause` / `pause` | Poke `df.global.pause_state`. DFHack 0.47 has no `fpause 0`. |
| `probe <unit_id>` | Publish one full profile in `probe_data` for ~5s. |
| `build <subcommand>` | Run `antfarm_blueprint <subcommand>` (next/auto on/status...). |
| `nick <unit_id> <name>` | Set a unit's nickname (backs the Twitch `!name` claim). |
| `ui <sub>` | Drive the modal watchdog (`status`/`screen`/`dismiss`/`unpause`/`on`/`off`). |
| `command <dfhack_cmd>` | Run any DFHack console command. |
| `stop` | Shut the bridge down and release the camera. |

### 5.4. Heartbeat safety
The server releases the camera lock (`df.global.ui.follow_unit = -1`) and drops to `idle` if no command arrives for 5 seconds, so a crashed client always returns control to the player. Clients must send `ping` or `mode` about once a second.

### 5.5. Auto-start
`antfarm_server start` is registered in `dfhack-config/init/onMapLoad.init`, which fires once a fort map is live. It is deliberately **not** in `dfhack.init`: that runs before any world is loaded. Comment the line out for a completely untouched game.

### 5.6. Available DFHack automation plugins
Agents can enable the following via the `command` verb:
*   **Labor**: `autolabor`, `labormanager`
*   **Livestock**: `autobutcher`, `autonestbox`
*   **Farming**: `autofarm`, `seedwatch`
*   **Clothing**: `tailor`, `autoclothing`, `cleanowned`
*   **Trade**: `autotrade`, `caravan` (list/extend/happy/leave)
*   **Construction**: `buildingplan`, `autounsuspend`
*   **Resources**: `autochop`, `automelt`, `autodump`
*   **Workflow**: `workflow`, `orders sort`, `prioritize`
*   **Maintenance**: `ban-cooking`, `combine-plants`, `combine-drinks`, `warn-starving`

## 6. History of Bug Fixes & Technical Pitfalls (For Future AI Agents)

Future agents working on this codebase MUST review these documented pitfalls before modifying DFHack scripts or socket IPC logic:

### 6.1. DFHack API Gotchas
1. **Designation Enums**: Use `df.tile_dig_designation.Default`, `df.tile_dig_designation.DownStair`, `df.tile_dig_designation.UpDownStair`. Do NOT use `df.tile_designation_type` (it does not exist).
2. **Tile Flags**: Use `flags.dig` (not `flags.designation`). Use `block.flags.designated` (not `block.flags.designation_dirty`).
3. **Tile Flag Checks**: Do NOT check `flags.damp` or `flags.warm` directly on designation flag structs (they do not exist on that struct). Check liquid/material types via `df.tiletype.attrs[tt].material` instead.
4. **DF Vector Indexing**: DFHack vectors are **0-indexed** C++ structures (`0` to `#vec - 1`). Using `ipairs()` on DF vectors can skip element 0 or fail. Always use `for i = 0, #vec - 1 do`.
5. **Overlay Script Loading**: Pure-Lua overlay scripts must live in `hack/scripts/` (e.g. `antfarm_overlay.lua`), NOT `hack/lua/plugins/` (which is reserved for compiled C++ `.plug.so` plugins). Script overlays must include `if dfhack_flags.module then return end` at the end of the file.
6. **Plugin Enable vs Require**: Do NOT run `dfhack.run_command("enable luasocket")` — `luasocket` is a C++ module library, not an enableable plugin tool. Load it via `pcall(require, "plugins.luasocket")`.
7. **Luasocket `accept()` Return Value Trap**: `luasocket.tcp:bind()` returns `server{server_id=-1}` on bind failure (not `nil`), and `server:accept()` returns `client{server_id=..., client_id=-1}` when no non-blocking socket connection is pending (not `nil`). You MUST explicitly check `server.server_id ~= -1` and `client.client_id ~= -1` before invoking methods on them. Calling methods or `close()` on a client object with `client_id == -1` will invoke `lua_server_close()` and cause a C++ segfault crash in Dwarf Fortress!
8. **`TranslateName(nil)` Crash**: `dfhack.TranslateName(dfhack.units.getVisibleName(u))` will raise a Lua exception if `getVisibleName(u)` returns `nil` (e.g. for unnamed units, wild animals, or transient units). Always check if `getVisibleName(u)` is non-nil or wrap inside a `pcall()` safe helper.
9. **`dfhack.timeout` units -- there is no real-time unit.** Measured on this build, the only accepted modes are `frames`, `ticks`, `days`, `months`, `years`. `msec`, `milliseconds`, `ms`, `seconds` and `sec` all raise `bad argument #2 to 'timeout' (invalid option ...)`. An earlier version of this entry recommended `"msec"`, which made `antfarm_server` fail to start entirely.

   **Use `frames`, not `ticks`, for anything that must keep running while the game is paused.** `ticks` are simulation time and stop dead on pause. Measured over 12s with the game paused: a `frames` timeout fired 1120 times, a `ticks` timeout fired 0. The IPC bridge, auto-unpause and the dashboard all have to work while paused, so they are frame-driven.

   Frame rate varies, so schedule on frames and gate the actual work on a wall clock (`dfhack.getTickCount()`, which returns real milliseconds) to hold a steady cadence. `antfarm_server.lua` does this: called every frame, does work every 200ms.

10. **`onLoad.init` / `onMapLoad.init` execution timing**: these run during the save-loading completion phase. Delay the first map scan (`antfarm_server` waits 60 frames) so DF finishes viewscreen and map-structure initialisation first.

11. **`unit.flags1.dead` does not exist in this build.** Reading it raises `Cannot read field unit_flags1.dead: not found`, and because it sat inside the state serialiser the whole bridge produced no output while logging only a generic failure. Use `dfhack.units.isActive(unit)` (or `isDead`) -- the API helpers are stable across versions, the bitfield names are not. Prefer `dfhack.units.*` over raw flag access everywhere.

### 6.2. Critical Game Stability Fixes & Settings

> **Verify before you trust this list.** As of 2026-09-12 several of these were
> documented here as "applied" while the tree said otherwise -- TWBT was still
> loaded, `PRINT_MODE` was `2D`, and `libsuppressdialog.so` was still preloaded,
> and DF was core-dumping in `Core::loadScriptFile` on every save load as a
> result (`gdb_crash_trace.txt`). They have now been re-applied and each entry
> below names the file to check. Graphics packs ship their own `init.txt` and
> per-save `onLoad_gfx_*.init`, so **re-check this list after installing one.**

1. **`[TEMPERATURE:YES]` required** -- `data/init/d_init.txt`. Never set `[TEMPERATURE:NO]` on an existing save with magma, fire, ice, or melt jobs: DF's item update engine dereferences null temperature structures and segfaults within 5-10 seconds of unpausing.
2. **`[PRINT_MODE:2D]`** -- `data/init/init.txt`. **Do not change this to `STANDARD`.**

   This entry previously claimed the opposite, and acting on it hung the game on 2026-09-12: the window opened and never loaded. `STANDARD` makes DF negotiate OpenGL buffering; when that fails on modern Mesa, `libgraphics.so` (which links `libgtk-x11-2.0`) raises a *modal* "Requested single-buffering not available" dialog and blocks in `gtk_dialog_run` forever. `libs/libsuppressdialog.so` used to dismiss it, so the two settings had been masking each other -- removing the preload (6.2.3) and switching to `STANDARD` in the same pass is what surfaced it.

   `2D` is the SDL software renderer and never runs that negotiation, so the dialog cannot appear. `init.txt` says so itself: *"By and large, 2D should be the most reliable... On a multi-core machine none of this is very likely to matter; stick to 2D."*

   Disabling TWBT is a **separate** fix (6.2.6) and does not require touching the renderer. Verified: DF reaches the title screen with `2D` + TWBT disabled + no dialog suppressor.
3. **No `libsuppressdialog.so` in `LD_PRELOAD`** -- `df` and `dfhack`. Its `dlsym`/GTK interception corrupts memory. `libGL.so.1` and `set_ptracer_any.so` stay; only the dialog suppressor is removed.
4. **`enable autolabor`** -- `dfhack-config/init/onMapLoad.init`. **Now ON**, reversing the old advice. Without labor automation an unattended fort cannot build itself: only the two dwarves who embarked with the mining labor ever dig, and everyone else idles beside thousands of designated tiles. Enabling it took assigned miners from 2 to 4 on a live fort with no instability over the period tested (minutes, not hours).

   The previous "causes labor-flag memory conflicts" warning is not credible: the `autolabor 0` that was supposed to enforce it lived in `dfhack_PyLNP.init` and failed on **every** startup with `World is not loaded`, so the documented-off state was never actually in force and the instability was never observed with autolabor genuinely disabled. Treat this as a warning to re-test, not as established fact.

   Note it logs every dwarf every cycle (~45k lines/hour into `stderr.log`); `start_antfarm.sh` truncates the logs at launch.
5. **Antfarm auto-start lives in `onMapLoad.init`, not `dfhack.init`** -- `dfhack.init` runs before any world exists, so starting the bridge there gave it no map to read. `dfhack-config/init/onMapLoad.init` fires once a fort is live. Comment that one line out for a fully vanilla launch.
6. **TWBT plugin renamed to `hack/plugins/twbt.plug.so.disabled`** -- DFHack auto-loads *every* `.plug.so` at startup. Whatever the print mode, TWBT installs C++ vtable interpose hooks on every building's `drawBuilding` and on `dungeonmode_hook::feed/logic`, which segfault when its rendering expectations do not match the active print mode. Changing `PRINT_MODE` alone is not enough.
7. **Per-save graphics init scripts must be cleared too** -- DFHack auto-loads `raw/onLoad_gfx_*.init` from both the base DF directory **and every save** (`data/save/region1/raw/onLoad_gfx_Phoebus.init`). Phoebus ships `twbt unit_transparency 1` there, which re-invokes TWBT on every load even with the plugin disabled. This is the crash in `gdb_crash_trace.txt`: `handleLoadAndUnloadScripts -> loadScriptFile -> runCommand`. Both files are now commented out.
8. **Non-interactive STDIN** -- when a GUI launcher or `start_antfarm.sh` spawns DFHack via `nohup`/`subprocess`/`setsid`, STDIN is `/dev/null`.

   Measured on this build: DFHack prints `Initializing Console.` / `could not open tty` / `Console has failed to initialize!` and then **continues normally** -- every plugin loads and DF reaches the title screen. The `fIOthread` EOF spin this entry used to describe does not occur here.

   `export DFHACK_DISABLE_CONSOLE=1` under `[ ! -t 0 ]` is kept in `dfhack` as defence in depth, but **it changes nothing in this build**: an A/B run with the variable at `1` versus `0` produced identical console output. Do not cite it as the reason anything works.

### 6.3. Init-File Errors Found by Reading the Startup Log

Both of these ran on every launch and failed silently. **Read `game/stderr.log` after a launch** -- DFHack logs every `Invoking:` line and its result there, and that is where both of these were hiding in plain sight.

1. **`autolabor 0` was never in force.** It lived in `dfhack-config/init/dfhack_PyLNP.init`, which runs at DFHack init *before any world is loaded*, where the command fails with `World is not loaded: please load a game first`. Moved to `onMapLoad.init`. Anything that touches world state belongs there, not in `dfhack.init`/`dfhack_PyLNP.init`.
2. **`fix/feeding-timers` does not exist in this DFHack.** PyLNP's generated init registered a `repeat` job for it, logging `fix/feeding-timers is not a recognized command` on every startup. Removed. The `fix/` scripts that *do* exist: `blood-del`, `corrupt-equipment`, `dead-units`, `drop-webs`, `dry-buckets`, `item-occupancy`, `loyaltycascade`, `population-cap`, `retrieve-units`, `stable-temp`, `stuckdoors`, `stuck-merchants`, `tile-occupancy`.

> Both of these lived in `dfhack_PyLNP.init`, which PyLNP regenerated on every
> settings change. That file and the launcher are gone; anything that must run
> once a world exists belongs in `onMapLoad.init`.

3. **`autonestbox start` does nothing.** The plugin exposes `plugin_enable`, so the verb is `enable autonestbox`; `autonestbox start` just logs `autonestbox is not running`.
4. **`combine-plants` / `combine-drinks` cannot run unattended.** Both require a selected stockpile or container (or an explicit `-stockpile`/`-container`), so a `repeat` job for them logs `Select an item or building` every cycle and does nothing. Removed from `onMapLoad.init`.

### 6.4. The Surface Is The Level Dwarves Stand On

Picking the fort's surface z-level as "the highest mostly-solid level" is wrong
and silently breaks everything downstream. A real column looks like:

```
z=42  EMPTY / AIR    OUTSIDE
z=41  FLOOR / SOIL   OUTSIDE   <- dwarves stand here; this is the surface
z=40  WALL  / SOIL             <- first *solid* level; soil, so this is farming
z=39  WALL  / STONE            <- first rock; this is industry
```

Choosing z=40 put the entire surface fort one level inside the dirt, so no
stairway joined the dug levels to where the dwarves were. Symptom: thousands of
tiles designated, every dwarf reporting `Idle`, and no mining jobs ever created,
because the excavation was unreachable. It also broke the farming survey -- the
soil layer *is* z=40, but the scan started below it and reported "no soil layer".

Detect the surface as the highest level whose tiles are predominantly
**walkable** (`FLOOR`, `RAMP`, `STAIR_*`, `BOULDER`, `PEBBLES`, `SHRUB`,
`SAPLING`) -- not merely "not a wall", since `EMPTY` air is also not a wall. The
first diggable level is then `surface - 1`.

Verify with a column probe before trusting a survey: print shape/material/`dig`
for each z at the anchor and check it against where citizens actually are
(`unit.pos.z`).

### 6.5. Verifying Against a Live Fort

DF cannot be driven headlessly, but it *can* be driven non-interactively:

```bash
cd game
./dfhack +load-save region1          # loads a save with no keyboard input
```

Add `+<script>` to run any script at startup. With a save loaded, commands can be
injected through the bridge's own spool without touching the keyboard:

```bash
printf '{"command": "command antfarm_blueprint survey"}' > game/antfarm_cmd/probe.json
```

Script `print()` output and DFHack's own `Invoking:` lines land in
`game/stderr.log`, **not** on the terminal. Read that file, and allow a
few seconds of latency before concluding a command produced nothing.

**`print()` is not a reliable channel here.** The console fails to initialise
under a non-interactive stdin (6.2.8), and script output sometimes never reaches
`stderr.log` at all -- `antfarm_worlds` printed nothing for a minute while the
same code wrote a file instantly. For any probe whose output you actually need,
write it to a file in the DF directory and `cat` it. `antfarm_worlds.lua` keeps
both paths for exactly this reason.

Prefer the `command` verb over `build` when diagnosing: `command` reports errors,
and a bare `pcall` around `run_command` turns a script error into silence.

**Undo is safe.** `quickfort undo <file> -n <blueprint> --cursor x,y,z` removes
exactly what that blueprint designated, so a misplaced build can be rolled back
and re-applied once the survey is right.

**Never run the test suites against the live game directory.** They write a fake
state file and send commands, and a running fortress will execute them -- a test
nickname ended up on a real dwarf this way, and the suites themselves fail
because the live bridge overwrites their fixture five times a second. Set
`ANTFARM_DF_DIR` to a scratch directory; `antfarm/client.py` honours it for both the
state file and the command spool.

---

## 7. Twitch Interactive Layer

`antfarm/twitch.py` bridges Twitch chat into the Antfarm event loop over plain IRC/TLS (no third-party dependency). It is optional: with no credentials configured the bridge stays dormant and the dashboard behaves exactly as before.

### 7.1. Configuration
Environment (`TWITCH_NICK`, `TWITCH_TOKEN`, `TWITCH_CHANNEL`) overrides `config/twitch.json`. See `config/twitch.example.json`. **Never commit a real token.**

### 7.2. Viewer commands
| Command | Effect |
| --- | --- |
| `!next` | Pan to the next dwarf down the interest ranking. |
| `!focus <name>` | Lock the camera onto a dwarf by nickname or name. |
| `!stats` `!skills` `!health` `!kills` `[name]` | Readouts; default to the caller's claimed dwarf, then the focused one. |
| `!name [dwarf]` | Claim an unclaimed citizen; sets the in-game nickname to the viewer's login. |
| `!mine` `!who` `!fort` | Ownership and fortress status. |
| `!vote <n>` | Vote in the open poll. |
| `!poll Q \| a \| b` , `!director <mode>` | Moderator/broadcaster only. |

### 7.3. Invariants to preserve when editing
*   **Camera arbitration**: a chat `!focus` calls `engine.viewer_focus()`, which sets `override_until`. While that is in the future `_handle_rotation` refreshes the lock but does not steer, so the Director cannot overrule a viewer one second later. Any new camera path must respect `override_active()`.
*   **Rate limits**: Twitch disconnects a non-mod bot over 20 messages / 30s. `say()` caps at 18 and drops the excess. Per-user command cooldown is 8s; `!vote` is exempt or most votes in a poll would be silently dropped.
*   **Claims** are stored in `state/claims.json` *and* as the in-game nickname, so a lost file does not orphan a viewer's dwarf. One dwarf per viewer.
*   **Auto-announcements** are restricted to `CitizenDeath` and `CitizenEnteredCombat`. Job start/finish events fire many times per second and would flood chat.

### 7.4. Plugin SDK
Drop a file exporting a `Plugin` class (deriving from `antfarm.sdk.BasePlugin`) into `antfarm/plugins/`; it is auto-loaded at engine start and receives the event bus and live knowledge graph. See `antfarm/plugins/README.md` and `example_obituary.py`. Plugin exceptions are logged, never fatal.

### 6.6. Worldgen Must Leave Room For The Fort

`TOLKIEN_EPIC_LARGE`/`MEDIUM` shipped with `[LEVELS_ABOVE_LAYER_1:5]` -- only
five z-levels of rock between the surface and the first cavern. Dreamfort
occupies the surface, a farming level and **twelve** rock levels (industry down
to apartments-4), so the fort was dug straight into cavern 1. Symptoms: repeated
`Digging designation cancelled: damp stone located`, and blocking
`You have discovered an expansive cavern` / `a magma pool` /
`a great magma sea` popups.

Both presets are now `[LEVELS_ABOVE_LAYER_1:20]` with `_2`/`_3` at 4 and `_4` at
3 so the deeper layers are not stacked either. **Any worldgen preset used with
the guided build needs at least ~15 levels above cavern 1.**

Regenerate headlessly -- no keyboard needed:

```bash
cd game
./df -gen <id> RANDOM TOLKIEN_EPIC_LARGE     # id must not already exist
```

It writes `data/save/region<id>/`, exports `region<id>-000NN-*` files (the NN is
the start year, so it doubles as a check that `[END_YEAR]` took), and exits. A
257x257 world with 50 years of history takes well under a minute.

### 6.7. Blocking Dialogs Halt An Unattended Fort

This is the single biggest cause of a dead stream, and DF has two separate
mechanisms for it. `antfarm_ui` handles both; read it before touching either.

**1. Mega-announcement popups.** DF queues "You have discovered..." messages in
`df.global.world.status.popups` and **halts until someone presses Enter** -- the
viewscreen stays `viewscreen_dwarfmodest`, so checking the screen type will not
find them.

Clear them by feeding `CLOSE_MEGA_ANNOUNCEMENT` (Enter) to the current
viewscreen, **not** by erasing the vector. The vector holds owned pointers;
erasing them leaks the messages and skips whatever else DF does on dismissal.
`antfarm_ui` keeps the direct `popups:resize(0)` only as a last resort after the
key has failed several times, and reports it as a failure when it happens.

`pause_state = false` does **not** unpause a game with a popup queued: DF
re-pauses immediately. Clear the popup first, then unpause. This is why the
Python-side auto-unpause was removed -- it could not work from where it was.

**2. Blocking viewscreens.** The liaison's meeting, a caravan agreement, a text
viewer. These are real screens on the stack. The key for each, taken from df-ai
`pause.cpp`:

| Viewscreen | Key |
| --- | --- |
| `viewscreen_topicmeetingst` | `OPTION1` (not `SELECT`) |
| `viewscreen_topicmeeting_takerequestsst` | `LEAVESCREEN` |
| `viewscreen_topicmeeting_fill_land_holder_positionsst` | `LEAVESCREEN` |
| `viewscreen_requestagreementst` | `LEAVESCREEN` |
| `viewscreen_textviewerst` | `LEAVESCREEN` |

Three rules are load-bearing:

* **Never send a key to a screen with no parent.** `LEAVESCREEN` on
  `viewscreen_dwarfmodest` opens the abandon-fortress menu, and
  `dfhack.screen.dismiss` on a parentless screen **exits DF immediately** (see
  `devel/pop-screen`).
* **Never touch the world-setup screens** (title, load game, embark, worldgen).
  The operator is using them.
* **Verify the screen before every keystroke.** `antfarm_ui`'s coroutine driver
  (`start_driver`) exists for this; it is a port of df-ai's `ExclusiveCallback`.
  Blind keystrokes are how UI automation corrupts a fort.

`AUTO_DISMISS_POPUPS = false` at the top of `antfarm_server.lua` leaves
everything for a human. Viewscreen dismissal is separately gated on a client
actually driving the fort, so playing by hand is never interfered with.

### 6.7.1. Classify Pauses By Announcement Type, Not Text

`d_init.announcements.flags[<announcement_type>].PAUSE` says whether a given
announcement type is configured to pause the game -- it is what DF itself keys
on. The pausing event is the most recent announcement of a type with that flag
set whose `year`/`time` match `cur_year`/`cur_year_tick`.

Searching announcement *text* for words like "attack" or "siege" does not work
and actively breaks the fort:

* combat spam during any fight matches "attack";
* `announcements[0]` is the newest announcement and stops changing once the
  fighting ends, so the match never clears and auto-unpause stays suppressed for
  the rest of the session.

That was a real, shipped bug. `antfarm_ui.pause_cause()` and `classify_pause()`
replace it. Any new danger heuristic belongs there, keyed on
`df.announcement_type`, not on words.

Two more things df-ai gets right and we now do too:

* **A stuck-pause backstop.** However good the classification, something will
  eventually pause the game in a way nothing recognises. If the game has been
  paused or popup-blocked for ten seconds with nothing clearing it, force it.
* **Restore the camera after unpausing.** An announcement with `RECENTER` drags
  the view to the event and drops `ui.follow_unit`. `antfarm_server` tells
  `antfarm_ui` which unit the Director has locked, and the watchdog re-applies
  it after every unpause.

### 6.7.2. Prior Art: Read df-ai Before Solving This Yourself

`https://github.com/BenLubar/df-ai` is a complete autonomous fortress AI for
this exact DF version, and it hit every one of these problems first. Before
building any new automation here, check what it already does:

| Where | What |
| --- | --- |
| `pause.cpp` | popup/viewscreen dismissal, pause classification |
| `ai.cpp` | `is_dwarfmode_viewscreen()`, the stuck-pause watchdog, `timeout_sameview` |
| `exclusive_callback.{h,cpp}` | the verify-screen-then-send-key coroutine pattern |
| `camera.cpp` | `ignore_pause()`, primary-antagonist target selection |
| `population_occupations.cpp` | `CheckPetitionsExclusive` -- answering petitions |
| `CHANGELOG.md` | a list of hard-won fixes worth reading end to end |

Where it stops, and where the work here is:

* It only dismisses screens it recognises, by matching exact English diplomat
  dialogue; an unrecognised screen logs an error and the fort stays frozen. Our
  unknown screens are dismissed too, after a longer grace.
* Its `unpause()` is `while (!popups.empty()) feed_key(...)` -- unbounded. If
  the key ever fails to take, DF hangs inside the plugin. Ours is bounded.
* It has no notion of an operator being present; it assumes full autonomy.
* It replaces the fort planner entirely. We drive Dreamfort instead, so its
  `plan_*.cpp` is reference, not something to port.

### 6.7.3. Field Names And Types Verified Against A Live Fort

Four things that looked right, passed the stub tests, and were wrong in the game.
All four were found by driving a real fortress with `dfhack-run`; none could have
been found by reading the code.

1. **`df.global.world.job_list` does not exist. It is `world.jobs.list`.**
   Reading the wrong one raises, and because `auto_tick` called `gate_open`
   unguarded, the first `gate = 'build'` step killed the timeout chain and auto
   mode stopped for the rest of the session with nothing in the log. Gate checks
   are now wrapped in `pcall` everywhere, and `tests/df_stub.lua` makes
   `utils.listpairs(nil)` an error so a wrong field name fails a test.

2. **`world_data.region_map` is `region_map_entry**`.** `region_map[x]`
   dereferences to the *first entry of column x*, not to an indexable array;
   `region_map[x][y]` silently reads a field named `y` off an entry and raises.
   The y index is `region_map[x]:_displace(y)`.

3. **`in_embark_aquifer` and friends are real Lua booleans, not 0/1.** They are
   `BooleanEnum` in df-structures and DFHack converts them. Testing `v ~= 0`
   reports every flag as SET, because in Lua `false ~= 0` is true -- a boolean is
   never equal to a number. That made every candidate embark look like it had an
   aquifer.

4. **`gui.simulateInput` QUEUES a key; DF feeds it on a later frame.** Checking
   whether the screen closed in the same call always reads the pre-keystroke
   screen. The watchdog dismissed screens correctly but recorded every one as a
   failure. Verification is now deferred to a later tick (`confirm_pending`),
   which is also what df-ai's `timeout_sameview` does. `tests/df_stub.lua` has an
   `async_keys` mode that models this.

**The lesson: `pgrep -f`, field names, and enum types all need checking against
the running game.** `game/dfhack-run <command>` drives a live fortress from a
shell without touching the keyboard, and is the fastest way to verify any of it.

### 6.7.4. Wire Formats Need Testing From Both Ends

`DFClient.send_cmd` strips the command string. `set_nickname(id, "")` therefore
arrives as a bare `nick <id>` with no trailing space, and the server's
`'^(%S+)%s+(.*)$'` pattern -- which requires whitespace -- rejected it. Every
nickname *clear* was silently dropped, so a viewer who released their dwarf left
it nicknamed, it still counted as claimed, and nobody could ever take it.

`tests/test_wire.py` now generates command files with the real client and parses
them with the real Lua reader, covering the clear form, accented names, quotes,
backslashes and above-BMP emoji. Add a case there for any new verb.

### 6.8. Two Save Menus, And Generated Worlds Are In The Other One

DF splits saves across two title-screen lists, and a freshly generated world
looks "missing" if you check the wrong one:

| Menu | Structure | Contains |
| --- | --- | --- |
| Continue Playing | `viewscreen_loadgamest.saves` | worlds **with an active fortress** (`world.sav`) |
| Start Playing | `viewscreen_titlest.start_savegames` | worlds with **no fort yet** (`world.dat`) -- embark here |

`./df -gen ...` produces the second kind, so it never appears under "Continue
Playing". DFHack's own `load-save` script says as much: *"inactive saves (i.e.
saves under the 'start game' menu) are currently not supported."*

`antfarm_worlds` lists every world on disk and says which menu each one is
under; run it on the title screen and it also dumps DF's own `start_savegames`.

### 6.9. Gate Each Build Step On Its Own Level, Not The Whole Fort

The guided build originally gated every `dig` step on "no outstanding
designations anywhere in the fort". That is wrong and it starves the fortress.

`/surface2` is the step that builds the **starting workshops -- including the
still -- and the food stockpiles**. Gated on the whole excavation, it sat behind
all ~6000 tiles of `/dig_all`, which takes in-game months. Observed on a live
fort: 27 drinks left, thirst counters climbing on all seven dwarves, and
`farm plots built: 0   stills built: 0`.

Dreamfort's checklist is explicit that each step waits only on its own level
("Run when the farming level has been dug out"), so `gate_levels` now defaults
to the step's own level, with two documented overrides -- `/surface2` and
`/farming1` both wait on **surface** work (tree clearing and channels), not on
their nominal level.

Supporting changes:
* `prioritize -a Brew PlantSeeds ProcessPlants ProcessPlantsBarrel MillPlants PrepareMeal`
  in `onMapLoad.init`. `prioritize defaults` does **not** cover brewing or farm
  work, so those jobs queued behind thousands of mining jobs. The 0.47 job type
  is `Brew`; there is no `BrewDrink`.
* `library/basic` orders now import at step 5 instead of 6 -- it carries the food
  and plant-processing orders and was arriving far too late. Note it contains no
  brewing order at all, which is why the `prioritize` line matters.

Diagnose this class of problem by probing stocks directly rather than trusting
the build to be progressing:

```lua
-- count DRINK / FOOD / PLANT / SEEDS in df.global.world.items.all,
-- and read u.counters2.thirst_timer / hunger_timer per citizen
```
