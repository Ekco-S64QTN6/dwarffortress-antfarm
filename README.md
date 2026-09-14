# Dwarf Fortress Antfarm

A pre-configured Dwarf Fortress 0.47.05 install wired for **unattended
streaming**. The fort digs, builds and runs itself from community-tuned
blueprints, a Director AI drives the camera by live event scoring, a watchdog
answers the dialogs that would otherwise stop the game dead, and Twitch chat can
steer the whole thing.

```bash
./start_antfarm.sh          # game / dashboard / chat bridge / status
./tests/run_all.sh          # everything that can be checked without the game
```

---

## Contents

| Path | What it is |
| --- | --- |
| `antfarm/` | Antfarm: IPC client, Director AI, TUI dashboard, Twitch bridge, plugins |
| `game/` | The game, DFHack, and the `antfarm_*.lua` in-game scripts |
| `tools/` | Bundled utilities and their launchers: Dwarf Therapist, Legends Browser, SoundSense, Announcement Window |
| `tests/` | Unit tests and a stubbed `df`/`dfhack`, so the logic runs without the game |
| `docs/` | This project's documentation |
| `config/` | Your credentials. Gitignored; copy `config/twitch.example.json` to start |
| `state/` | Runtime data: claims, the generated Legends database. Gitignored |

Documentation:
[fortress construction](docs/fortress-build.md) ·
[code review & outcomes](docs/code-review-2026-09-13.md) ·
[settings audit](docs/settings-audit.md) ·
[modding notes](docs/modding.md) ·
[automation research](docs/automation-research.md) ·
[agent & maintainer guide](AGENTS.md)

**Jump to:**
[Running it](#1-running-it) ·
[Choosing an embark](#2-choosing-where-to-embark) ·
[Building the fortress](#3-building-the-fortress) ·
[Director AI](#4-the-director-ai-and-dashboard) ·
[Keeping the game running](#5-keeping-the-game-running) ·
[Twitch](#6-twitch-integration) ·
[Linux notes](#7-linux-compatibility) ·
[Tests](#8-tests) ·
[Worldgen](#9-worldgen-presets)

---

## 1. Running it

Start the game and the dashboard in either order — the dashboard waits for the
game and picks it up automatically.

```bash
cd game && ./dfhack      # terminal 1: the game
./.venv/bin/python -m antfarm.tui      # terminal 2: the dashboard
```

The in-game bridge starts by itself when a save loads. Close the dashboard and
the camera returns to you within five seconds.

Option 6 of `start_antfarm.sh` launches the bundled utilities — Dwarf Therapist,
Legends Browser, SoundSense, Announcement Window — or run them directly from
`tools/`.

> **PyLNP is deliberately not included.** Its Tk launcher rewrote
> `data/init/init.txt` and the DFHack init files every time a graphics pack was
> switched, which kept undoing the crash fixes in section 6 — and its generated
> `dfhack_PyLNP.init` duplicated the housekeeping jobs in `onMapLoad.init`. The
> two commands worth keeping from it (`tweak fast-heat`, `fix/stuckdoors`) now
> live in `onMapLoad.init` where they can be read and edited.

### Dashboard keys

`d` Director AI · `t` timed rotation · `e` event-driven · `i` idle (manual
camera) · `r` force rotate · `b` next build step · `B` build auto on/off ·
`u` dismiss whatever the game is stopped on · `q` quit

---

## 2. Choosing where to embark

`antfarm_embark` picks the site, because nothing else did — the guided build
chose where to put the fort *within* an embark, but a human still had to sit
through site selection first.

It ranks every 4x4 rectangle in the world on what the rest of the system
actually needs, with **flatness first**: the surface fort is what viewers see,
and elevation running through it reads as rubble on camera. Then no aquifer
(the geology survey refuses to dig one), not evil, not freezing, and enough
trees for the first workshops. Two passes — a whole-world scan of the region
map, then DF's own live aquifer verdict for each shortlisted rectangle.

```text
antfarm_embark scan     rank the sites, change nothing
antfarm_embark          take the best usable one and embark
```

From the site screen, **Ctrl-N / Ctrl-P** step the cursor through the shortlist
so you can look at each on camera, and **Ctrl-E** embarks where the cursor is.
Each step prints the site's stats and DF's aquifer/salt verdict.

Measured on a 129x129 Tolkien-preset world: 15,800 rectangles considered, 11
survived, best one anchored at 100% usable footprint.

---

## 3. Building the fortress

The dwarves build a genuine fort, not a warren of empty rooms. `antfarm_blueprint`
surveys the embark's geology, picks levels for each layer, and walks the
**Dreamfort** checklist — the community blueprint set that ships with DFHack —
gating every step on whether the previous one's digging and construction
actually finished.

```text
antfarm_blueprint autostart  # pick a site near the dwarves and start building
```

or, to choose the site yourself:

```text
antfarm_blueprint survey     # what is under the cursor
antfarm_blueprint here       # anchor the fort here
antfarm_blueprint auto on    # build it
```

Twenty-two steps take it from bare embark to a fort with a trap-corridor
entrance, farms, workshops, a hospital, tavern, guildhalls and apartments —
furnished, stockpiled and with rooms assigned. Manager orders are queued
automatically and the orders libraries are imported as the fort matures.

The dashboard does this for you on a **fresh embark** — no anchor, nothing
designated, a starting population. On an established fort it leaves well alone,
because designating several thousand tiles somewhere you did not choose is not a
recoverable mistake. `ANTFARM_AUTOBUILD=1` forces it on, `=0` forces it off.

Three things keep the build honest rather than merely optimistic:

* **Steps are verified, not assumed.** Quickfort reports success even when the
  cursor was out of bounds and it touched nothing, so its output is read back
  and the affected-tile count checked. A step that does no work is retried, and
  if it still does nothing the checklist records *which* step built nothing
  instead of quietly moving on — that failure mode is how a fort ends up with no
  still and no farm plots while the progress counter looks healthy.
* **Stalls are detected.** A gate whose outstanding-work count stops falling is
  stuck, not slow. After fifteen minutes of no progress the build unsuspends
  constructions, re-prioritises digging, and clears dig designations that touch
  water — the `damp stone` cancellation loop — then says so on the dashboard.
* **Nothing is applied while the game is not on the map.** Blueprints are only
  run from an idle map view, never with a menu or popup open, so keystrokes
  cannot land in the wrong screen.

`antfarm_blueprint unstick` runs the damp-stone sweep by hand;
`antfarm_blueprint simple` is a standalone digger for embarks where Dreamfort's
footprint will not fit. Full details in
**[docs/fortress-build.md](docs/fortress-build.md)**.

Standing automation — farming, livestock caps, workflow, seed and stock
management, housekeeping — lives in
`game/dfhack-config/init/onMapLoad.init`, where you can edit it
without touching code.

---

## 4. The Director AI and dashboard

Every citizen carries a live interest score: stress and stress *volatility*,
noble and legendary status, spatial crowding, relationship-graph degree, and
decaying event boosts — a death is worth 2000 with a ten-minute half-life,
entering combat 1000, a job change 100. The camera locks onto the leader and
holds it through a hysteresis threshold and a minimum follow time so it does not
ping-pong.

Modes: **director** (follow the most interesting dwarf), **timed** (cycle the
top five), **event** (snap to stress and strange moods), **idle** (hands off).

The dashboard is built for OBS capture: fortress stats and build progress, a
citizen profile card with a real stress sparkline sampled every two seconds,
gauges for sleep, food, drink and physical attributes, top skills, emotions, a
live announcement feed, family relationships cross-referenced against the
exported Legends archive, and a narrative story card that calls out strange
moods and combat.

Defence is automatic: name a lever `gate`, `drawbridge`, `portcullis`,
`floodgate`, `lockdown` or `defence` in game (`q` → the lever → `N`) and a
dangerous event queues a high-priority pull on it. The keyword list is
deliberately narrow — it used to include `door`, which matched *"Pantry Door"*
and sealed the fort away from its own food the moment a siege was announced.
`antfarm_lever list` shows what is enrolled and what a rename would add.

---

## 5. Keeping the game running

The thing that stops an unattended fortress is almost never the fortress. It is
a dialog box. The miners break into the caverns, DF puts up *"You have
discovered an expansive cavern!"*, and the entire simulation halts until someone
presses Enter. Nobody is there to press Enter. Every dwarf reports `Idle`
forever and the stream shows a still frame.

`antfarm_ui` is the watchdog for this, and it handles two different mechanisms
because DF uses two:

* **Mega-announcement popups** live in `world.status.popups` and are drawn
  *inside* the map view, so the screen type never changes and checking it will
  not find them. They are cleared with `CLOSE_MEGA_ANNOUNCEMENT` — literally the
  Enter key a player presses — so DF runs its own teardown.
* **Blocking viewscreens** — the liaison's meeting, a caravan agreement, a text
  viewer — are dismissed with `LEAVESCREEN`, escalating to `LEAVESCREEN_ALL` and
  then to a forced dismissal, after a grace period long enough that a human
  reading a menu is never fought for control.

Pauses are classified by the **announcement type** that caused them, read out of
`d_init`, which is what DF itself keys on. Matching the announcement *text* for
words like "attack" — the previous approach — also matched routine combat spam,
and once matched it never un-matched, so a single siege could suppress the
auto-unpause for the rest of the session. A dangerous event now holds the pause
for a few seconds so the audience sees it, then the game continues; the camera
lock is restored afterwards, because an announcement with `RECENTER` drags the
view away and drops it.

Also handled: petitions are answered rather than left to lapse, DFHack's
`confirm` plugin is disabled (every one of its dialogs is a stop), and the
combat/hunting report indicators are cleared so they stop reopening the report
list.

Everything it does is reported — on the dashboard header, in `!build`/status
output, and via `antfarm_ui status`. Press `u` on the dashboard to dismiss a
blocker by hand. Nothing but popups is dismissed unless a client is actually
driving the fort, so playing by hand with the bridge idle is unaffected.

> Much of this is ported from **[Ben Lubar's df-ai](https://github.com/BenLubar/df-ai)**,
> which solved the same problems in C++ years ago — the viewscreen/key table and
> the pause classification are its work. Where this goes further: df-ai only
> dismisses screens it recognises by matching exact English dialogue and leaves
> anything else frozen, its popup loop is unbounded, and it has no notion of an
> operator being present. See [docs/automation-research.md](docs/automation-research.md).

---

## 6. Twitch integration

Optional. With no credentials configured the bridge stays dormant and everything
above works unchanged.

```bash
cp config/twitch.example.json config/twitch.json   # then fill it in
# or: export TWITCH_NICK=... TWITCH_TOKEN=oauth:... TWITCH_CHANNEL=...
```

Get a chat token for the bot account at <https://twitchapps.com/tmi/>
(`chat:read`, `chat:edit`). Keep it out of version control.

| Command | Effect |
| --- | --- |
| `!next` | Pan to the next dwarf down the interest ranking |
| `!focus <name>` | Lock the camera onto a dwarf for 45s. Beats the Director AI |
| `!name [dwarf]` | Claim an unclaimed citizen; renames them to your handle, in game |
| `!stats` `!skills` `!health` `!kills` `[name]` | Readouts, defaulting to your own dwarf |
| `!mine` `!who` `!fort` `!build` | Who is yours, who is on screen, fort and build status |
| `!unclaim` | Give up your dwarf so you can claim another |
| `!vote <n>` | Vote in the open poll |
| `!poll Q \| a \| b` · `!director <mode>` | Moderators and broadcaster only |

Deaths and combat are announced and @-mention the dwarf's owner; a death opens a
poll on what the fort should do about it, at most once every five minutes. A
dwarf merely *leaving* the roster — banished, a visitor going home, a squad off
the map edge — is not announced as a death; that distinction is why chat used to
hold funerals for dwarves who had simply walked away.

Guard rails: 8s per-viewer command cooldown, 20s global cooldown on camera
grabs, one dwarf per viewer, and outgoing chat capped at 18 messages per 30s so
Twitch does not drop the connection. Commands that wait on the game run in a
bounded worker pool and shed load past it, so a raid cannot spawn a thread per
viewer. Claims live in `state/claims.json` *and* as the in-game nickname, so they
survive a restart.

Drop a `Plugin` class into `antfarm/plugins/` to hook the event bus and the live
knowledge graph — see `antfarm/plugins/README.md`.

---

## 7. Linux compatibility

These are applied and verified, and are load-bearing — the game crashed on every
save load without them:

* **OpenGL** — the launch wrappers preload `libGL.so.1`, fixing
  `libgraphics.so: undefined symbol: glXGetProcAddressARB`.
* **`PRINT_MODE:2D`, TWBT disabled** — TWBT installs vtable interpose hooks that
  segfault on modern Linux drivers; the plugin is renamed `.disabled` *and* the
  Phoebus per-save init that re-invokes it is commented out. Leave the renderer
  on `2D`: `STANDARD` negotiates OpenGL buffering, and when that fails on modern
  Mesa DF raises a modal GTK dialog and hangs with its window open.
* **No `libsuppressdialog.so`** — its `dlsym`/GTK interception corrupted memory.
* **Non-interactive stdin** — `dfhack` exports `DFHACK_DISABLE_CONSOLE=1` when
  stdin is not a TTY. Kept as defence in depth, but stated honestly: measured on
  this build it changes nothing. DFHack logs `Console has failed to initialize!`
  under a `/dev/null` stdin and then carries on loading every plugin normally,
  and an A/B run with the variable at `1` versus `0` produced identical output.

> These are settings, not code, and nothing in this repository re-applies them.
> If you install a graphics pack by hand, re-check every one of them afterwards —
> packs ship their own `init.txt` and per-save `onLoad_gfx_*.init`. `AGENTS.md`
> section 6 has the full history and reasoning.

---

## 8. Tests

Dwarf Fortress cannot be run headlessly, so everything that can be checked
without it, is:

```bash
./tests/run_all.sh
```

That covers Lua and Python syntax for every file, shell syntax for the
launchers, and unit tests for the logic that has no business needing a game:
the geology survey against synthetic strata, gate counting, blueprint step
verification, the modal watchdog against a stubbed viewscreen stack, pause
classification, interest scoring, plugin isolation and the chat command
dispatcher. `tests/df_stub.lua` is a fake `df`/`dfhack` that records every
simulated keystroke, so a test can assert *which key* the watchdog pressed at a
popup.

> **Never point the suites at the live game directory.** They write a fake state
> file and send commands, and a running fortress will execute them — a test
> nickname reached a real dwarf that way once. The Python suite sets
> `ANTFARM_DF_DIR` to a scratch directory to make that impossible.

---

## 9. Worldgen presets

Under **Design New World with Parameters**:

* **`TOLKIEN_EPIC_LARGE`** — 257×257, 25 years of history, dense civilisations,
  high beast density, deep caverns, dramatic topography.
* **`TOLKIEN_EPIC_MEDIUM`** — 129×129, 25 years, same savagery and megabeasts,
  generates in about a minute.

Both are tuned for the guided build, and the cavern settings are load-bearing:

| Setting | Value | Why |
| --- | --- | --- |
| `LEVELS_ABOVE_LAYER_1` | 20 | Dreamfort occupies a surface level, a farming level and twelve rock levels. At the stock 5 the fort is dug straight into cavern 1 — damp-stone cancellations and blocking discovery popups. |
| `CAVERN_LAYER_OPENNESS_MIN` | 70 | The stock 0–100 rolls a fresh value per layer, and a low roll gives twisting one-tile passages that wreck cavern pathing. |
| `CAVERN_LAYER_PASSAGE_DENSITY_MAX` | 40 | High density turns an open cavern back into a warren. |
| `CAVERN_LAYER_WATER_MAX` | 20 | Flooded caverns drown the fort the moment the miners break through. |
| `END_YEAR` | 25 | Enough history for a populated world; 500 years on the medium map took long enough to be worth aborting. |

Generate one without touching the keyboard:

```bash
cd game && ./df -gen 1 RANDOM TOLKIEN_EPIC_MEDIUM
```

> This world is deliberately hostile — 40 titans, 80 demons, night creatures and
> werebeasts. There is no military automation, so an unattended fort here will
> eventually lose. Turn the `*_NUMBER` and `*_CAP` values down for a fort that
> survives long enough to finish building.

---

## Credits

Antfarm itself was written by **Claude Opus 5** (Anthropic), from requirements,
direction and testing by Michael Schellhorn. See `LICENSE` for the full
authorship note and every upstream licence.

* **Dwarf Fortress** by Bay 12 Games.
* **[DFHack](https://github.com/DFHack/dfhack)** — the scripting layer all of
  this runs inside, and the **Dreamfort** blueprint set (by *Mike Stewart*, aka
  *Wittzeng*) that the guided build drives.
* **[df-ai](https://github.com/BenLubar/df-ai)** by Ben Lubar, originally Ruby
  by Yoann Guillot — the prior art for the modal watchdog. The
  viewscreen/interface-key table and the announcement-type pause classification
  in `antfarm_ui.lua` are ports of its `pause.cpp`.
* **Dwarf Therapist**, **Legends Browser**, **SoundSense-RS** and
  **Announcement Window** — the utilities under `tools/`, each by its own
  authors and under its own licence.

Antfarm's own code is `antfarm/`, `game/hack/scripts/antfarm_*.lua`, `tests/`
and the launcher; everything under `game/` and `tools/` is upstream and carries
its own licensing.
