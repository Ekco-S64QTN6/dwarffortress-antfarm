# Remaining work

Updated 2026-10-04 after a session spent running a fort end to end. See
[`FORT-CHECKLIST.md`](FORT-CHECKLIST.md) for what a fort needs and how to check it
with one command.

---

## 0. This session

### Fixed and verified on a live fort

| Thing | Evidence |
| :-- | :-- |
| **One-button startup** | `./start_antfarm.sh` took a cold machine to a playing fort in under 45s: world detect → DF window → dashboard → embark → build running |
| **Title→embark automation** | `antfarm_autostart.lua`; sequence mapped against a live 0.47 title screen, not guessed |
| **The arrival text** | An unattended embark sat on that textviewer indefinitely; now dismissed within a poll |
| **Embark on an occupied tile** | The scanner ranked a previous fort's own tile best, pressed `e` (which DF silently ignores) and logged "embarked." Now 4006 occupied tiles are rejected and the keypress is verified on a later frame |
| **Plan outliving its fort** | `antfarm_plan.json` is stamped with a fort identity and discarded on mismatch. A fresh 7-dwarf embark had been reporting "step 15/22, surface z=62" with its dwarves on z=63 of another map |
| **`site_id` is not a fort identity** | Two forts embarked without a save in between both came out id 460 ("Lemisber", "Odrozzas"). Identity now includes the embark origin and name |
| **A string in the z-level table** | `farming_mode` was stored in `levels`, which feeds `fort_zlevels()` (gate scans) and the `%d` status printer. Both broke; it lives on the plan now |
| **Six scripts using v50 APIs** | `fix/stuck-worship`, `fix/engravings`, `fix/stuck-squad`, `antfarm_autoslab`, `justice`, `allneeds` all raised on every run. Fixed and each verified by actually running it |
| **The stub was more permissive than the game** | It offered `getReadableName`, which 0.47 lacks — so autoslab's tests passed while the live fort raised. Removed; `isGhost` added |
| **Survival gated behind digging** | `antfarm_sustenance.lua`: still/kitchen/farmer's workshop placed regardless of build step, ground-only gathering zone on the densest shrubs, tool-limited labours capped to tools on hand |
| **Dwarves in the rain** | `antfarm_locations` now takes a bare dug indoor room as a meeting area when there is no dining furniture yet |
| **The fort checklist** | `antfarm_checklist.lua`: 19 read-only checks in five groups. First run found 2 critical failures and 4 gaps that had been invisible |

### Found and not yet fixed

1. **Furniture cannot be placed before it is made.** `place_beds()` in
   `antfarm_quarters` calls `constructBuilding` for beds; with no bed *items* in
   the fort DF cancels the job and the building vanishes. It reported "placed 7
   bed(s)" while creating none. The chain is: manager order → carpenter makes a
   bed item → *then* place it. The module needs to queue the order and only place
   when items exist.
2. **Work orders were not issuing at all.** 61 manager orders, every one
   `status.validated = false`, and no jobs at the still or carpenter — so no beds,
   no booze, nothing. Cause not established. The manager was appointed and had no
   office, which is the obvious suspect, but an earlier fort in the same setup
   completed `Brew drink from plant` with no office either, so that explanation is
   unproven. **Diagnose this before anything else**: it blocks the entire
   production economy, and both the bed and booze failures above are downstream
   of it.
3. **I crashed the fort chasing that.** Writing `status.validated`/`status.active`
   across the order list segfaulted DF silently — no error, no core, nothing in
   the log. Recorded as AGENTS.md 6.1.12: read those bits, never write them. The
   fort autosaved first and was recoverable.
4. **`frequency = Daily`** on the brew orders is worth checking — a daily order
   issues a limited batch per day, which on a young fort may simply be too slow.
5. **DFHack's load screen cannot be driven.** `dfhack/lua/load_screen` replaces the
   vanilla `viewscreen_loadgamest`, and `antfarm_autostart` has no handler for it —
   it sat there logging "DFHack is loading the save" indefinitely. The launcher now
   avoids the screen entirely by passing `+load-save <region>` when a fort exists,
   and autostart gives up after 60s with instructions rather than waiting in
   silence. Driving the screen properly is still unimplemented, so launching
   `./dfhack` bare on a fort save still needs one human keypress.
6. **A vendored init file errored on every startup.** `dfhack-dwarftherapist-labors.init`
   contained `:lua df.global.game.external_flag = 1`; `df.global.game` is a v50
   structure and does not exist here. Now commented out with the reasoning, and the
   v50 API test scans `.init` files as well as `.lua` — it had only looked at
   scripts, which is why this one survived the previous sweep.
7. **`Parse error: param job df.job`** appears during quickfort's startup config
   read. It is upstream quickfort, not ours, and appears harmless — but it has not
   been traced.

---

## 1. Verified in earlier sessions

These were exercised on the running fort (year 25, pop 31→59) in an earlier
session and produced the stated effect:

| Thing | Evidence |
| :-- | :-- |
| Embark metals survey | Reported 8 metals, correctly found **no iron** (only pyrite, which yields nothing) |
| Impossible-order reaper | Cancelled the `ForgeAnvil/IRON` order that had been cancel-spamming for a season |
| Trade depot placement | Built depot #229 at 101,96,62 — the fort had none, and had already missed two caravans |
| Noble appointments | Filled militia commander, sheriff, captain of the guard, dungeon master, hammerer |
| Meeting hall relocation | Moved the meeting area off the surface (z=62) into the dining room (z=61); retired the wagon zone |
| Bed room definition | Defined and assigned all 6 existing beds; queued 20 each of beds/doors/chests/cabinets |
| Survey hazard fix | Corrected survey now picks farming z=60 (99.8% soil, dry) instead of z=61 (37 water tiles) |
| Dashboard vitals | `sleepiness/hunger/thirst` counters now render; previously all three gauges read a needs list that has no such entries |

## 2. Done this pass, **unverified** (no live game)

| Thing | Risk | What verification needs to do |
| :-- | :-- | :-- |
| **Subsystem tick dispatcher** | Low | Confirm `subsystems` in `antfarm_state.json` updates and that each module's notes appear over ~15 min |
| **State aggregator rewrite** | Low | Confirm `housing.shortfall`, `trade.has_depot`, `metals.missing` show real values, not `0`/`true`/`[1,2]` |
| **`antfarm_military` enlist / schedule** | Medium | Needs an existing squad; confirm dwarves get `military.squad_id` set and training min_count is `filled-1` |
| **`antfarm_military create`** | **High** | Builds `df.squad` by hand. Run once manually, then open the military screen and confirm the squad is usable, nameable and assignable |
| **Meeting-hall population sizing** | Low | Confirm the hall grows past the furniture box without swallowing corridors |
| **Grazing pasture + farmer workshop** | Medium | Confirm the zone is created on grass and the workshop lands adjacent |
| **Elven caravan detection** | Low | Needs an elven caravan on the map |

### The one to be careful with

`antfarm_military create` is the highest-risk code in the project. This DFHack
build has no `dfhack.military` module and no `assignNoblePosition`, so squad
creation writes `df.squad`, `df.squad_position`, `df.squad_schedule_entry` and
the uniform specs directly. It is a faithful port of df-ai's
`military_find_free_squad`, which drove unattended 0.47 forts for years, but a
port is not a test.

Two deliberate safety properties, which should not be "tidied away":

* It is **not** called from `tick()`. Only `enlist` (into squads DF already
  accepted) and schedule retuning run autonomously.
* World-linking (`world.squads.all`, `ui.squads.list`, `entity.squads`) happens
  **last**. Everything before it builds a detached object, so a raise anywhere —
  the schedule construction is the least certain part, since DF stores twelve
  entries per alert as one block — unwinds with nothing referenced by the world.
  A partially-linked squad is corruption; a leaked unreferenced one is garbage.

---

## 3. Not implemented

### 3.1. Trade-screen driver — the biggest functional gap

The fort can now *reach* a caravan (there is a depot) and knows *what* it wants
and *who* is at the depot. It still cannot actually trade: selecting goods is
multi-step viewscreen UI.

This matters more here than on a normal embark — §1 established there is no iron
ore on this map, so trade is the only route to iron and steel, forever.

It must go through `start_driver()` with a `d:expect()` on every screen
transition and `tests/df_stub.lua` coverage asserting the exact key sequence, the
same way the petition driver works. Blind keystrokes on the trade screen are how
you gift a caravan your entire stockpile.

Related and also missing: the **elven wood embargo enforcement**. Race detection
exists and exports are pinned to stone, but nothing prevents a wooden bin being
offered, which is what actually triggers the war (AGENTS.md 6.27).

### 3.2. Strange moods

Gap #12. Nothing detects a moody dwarf, reads the claimed workshop's
`job_items`, or supplies what is missing. The last mood on the live fort
succeeded *by luck* — it wanted bauxite and the fort sits on 367 blocks of it.
The failure case is permanent: the dwarf goes insane and is lost.

The design is in [`AUTOMATION-GAPS.md`](AUTOMATION-GAPS.md) §12 and is tractable,
because `job_items` states the demand exactly — item type, material, quantity
wanted, quantity supplied. No guessing from announcement text. The escalation
ladder (unforbid → prioritise → queue production → butcher for bone → last-resort
`createitem`) is specified there.

### 3.3. Justice

Gap #9. `justice.lua` was downloaded but is **not wired into anything** — no
antfarm module, no verb, no tick. The sheriff and captain of the guard are now
appointed, but nothing reads the justice tab, interviews anyone, or convicts.
There is also still no jail: Dreamfort builds one at step 22 of 22, and the fort
is stalled at 11.

Note the trap recorded in AUTOMATION-GAPS §9(d): many "crimes" in an unattended
fort are unsatisfiable production mandates. On this embark a mandate for iron
goods is impossible *by construction*, and jailing a dwarf for the geology would
be worse than doing nothing. Justice must share the "impossible vs. not yet"
logic that `antfarm_orders.lua` already implements.

### 3.4. Targeted mining

Gap #3. The metals survey knows where every ore is (`min_z`/`max_z` per ore), so
the hard part is done, but nothing designates a tunnel to any of it. All the
fort's ore lies outside the Dreamfort footprint and mostly far below it —
tetrahedrite runs to z=1, the fort bottoms out around z=52.

### 3.5. Temples, taverns, libraries and guildhalls

Gap #6, partially done. The meeting hall is placed and the deity census works
(Lorbam 35 worshippers, Arzes 22, Kesh 20 — three deities clear the threshold for
dedicated temples). But creating an actual **location** means building an
`abstract_building` and binding it to the civzone, which is not implemented.

Consequence: `antfarm_ui.lua` still **declines every temple and guildhall
petition** (the `OPTION2` path), because there is no room planner to satisfy them.
That decline is deliberate and correct while this is missing — but it should be
flipped as soon as locations exist.

### 3.6. Fenced pasture

The pasture zone is created on grass with a farmer's workshop beside it, but it
is not **fenced** — no wall ring, no door. Building the enclosure is a
construction job the module does not queue.

### 3.6a. A known-good opening order

`docs/FORT-CHECKLIST.md` §3 now names the reference: **Captain Duck's 2012 tutorial
series**, the opening most players learned. Matching the subsystems against that
sequence — and asserting each step either happens or is deliberately skipped — is
the difference between a fort that does not die and a fort that is played well.

### 3.6b. Priority order

Knowing what a fort needs is not knowing when. Dreamfort's 22 steps are a curated
build order, but it assumes a player who notices the fort has no booze at step 7
and fixes it by hand. The rule now followed is **survival items are never gated** —
see `FORT-CHECKLIST.md` §3 — but that is a rule of thumb, not a schedule. Matching
a known-good step-by-step order (the 0.47-era tutorial series encode one) against
the subsystems is still to do.

### 3.7. No arbiter

Gap #11, and the structural one. `subsystems_summary()` is a reporter; the
dispatcher is round-robin. Nothing budgets labour between subsystems, so mining,
hauling, construction and military all draft from the same idle dwarves with no
notion of priority. The `assess()` / `decide()` / `act()` contract proposed in
AUTOMATION-GAPS §11 is unimplemented.

### 3.8. Housing at scale

`antfarm_quarters` defines and assigns beds and queues furniture, but it cannot
**place** furniture in the dug apartment rooms — that is Dreamfort's
`/apartments2` and `/apartments3`, steps 18 and 21. With the build stalled at 11,
53 of 59 citizens still have no bedroom. Unsticking the build is the real fix;
the module only covers beds that already exist.

### 3.9. Phase 4 blueprint swap

Untouched. The 99 curated community blueprints are in
`game/blueprints/community/`, but nothing selects Raynard Whirlpool housing or
Andrelius Windmill Villas over Dreamfort's boxy quarters.

---

## 4. Known wrong in the docs

* `HANDOFF_TO_CLAUDE.md` states `MIN_FARMING_DEPTH = 3` twice. The code says
  **2**, deliberately: the soil column on this embark is two levels deep, and a
  depth of 3 puts the farms in bare rock where no plot can be built without
  irrigating the floor to mud first. Do not change the code to match the text.
* `HANDOFF_TO_CLAUDE.md` §2.2 lists `fix/sleepers.lua` under "sleeping unit
  lock". It is the genuine DFHack script, but it is **adventure-mode only** — it
  clears `ALARM_INTRUDER` on camp army controllers. It is correctly not
  scheduled in `onMapLoad.init`.
* `community_blueprints/` is gitignored: it contains four nested `.git`
  directories from cloned repos, which git would record as broken submodule
  links. The curated, used copies live in `game/blueprints/community/`.

---

## 5. Suggested order

1. **Unstick the live build** (step 11/22). Almost everything else is downstream:
   no apartments, no jail, no grand dining hall, no guildhalls until it moves.
2. **Strange moods** — cheapest high-stakes win; loses a dwarf permanently when
   it fails.
3. **Verify `antfarm_military create`** once by hand, then let enlistment run.
4. **Trade-screen driver** — the only path to iron on this map.
5. **Locations**, then flip the petition handler from decline to accept.
6. **Justice**, reusing the orders module's impossible-vs-not-yet logic.
7. **Targeted mining**, then the arbiter.
