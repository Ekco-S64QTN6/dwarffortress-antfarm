# Remaining work

Updated 2026-11-01 after the live-smoke capture and workforce/order reliability fixes. See
[`FORT-CHECKLIST.md`](FORT-CHECKLIST.md) for what a fort needs and how to check it
with one command, and [`REVIEW-2026-10-31.md`](REVIEW-2026-10-31.md) for the
finding-by-finding review of the earlier report.

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

### Known gaps and live-validation work

1. **Furniture-order / bed-placement safety — implemented in PR #14; offline CI
   passed, live-fort behavior not yet verified.** `antfarm_quarters` omits the
   invalid `"material":"INORGANIC"` category field. It submits
   `__reduce_amount=true`; the vendored DFHack 0.47 `workorder.lua` matcher
   subtracts `amount_left` from equivalent open orders before creating only any
   remainder. The target is reported as submitted only when
   `dfhack.run_command()` returns `CR_OK`. Bed construction requires a free,
   finished `df.item_type.BED`; logs alone are not treated as finished beds.
   Accessory furniture is queued independently of the bed shortfall. Tick order
   submits workshop targets before scheduling bed construction, and status text
   says "queued" rather than claiming completed buildings. The 17-case quarters
   Lua suite and full no-game CI pass. Manager validation, actual item production,
   room ownership/extents and completed bedroom quality still need checking on a
   disposable live fort.
2. **Work orders were not issuing at all.** 61 manager orders, every one
   `status.validated = false`, and no jobs at the still or carpenter — so no beds,
   no booze, nothing. Cause not established. The manager was appointed and had no
   office, which is the obvious suspect, but an earlier fort in the same setup
   completed `Brew drink from plant` with no office either, so that explanation is
   unproven. **Diagnose this before anything else**: it blocks the entire
   production economy, and both the bed and booze failures above are downstream
   of it.

   A new **read-only** diagnostic is now available:
   `cd game && ./dfhack-run antfarm_orders audit`. It reports the current validated /
   unvalidated / unknown and active / inactive / unknown counts, plus impossible
   orders, stalled jobs and unmet job-item requirements. It reads the status bits
   but never writes them. Capture this output before changing the manager, office,
   work-order definitions or labour assignments. The
   [DF 0.47.05 Manager reference](https://dwarffortresswiki.org/index.php/DF2014:Manager#Work_orders)
   says that at 20+ citizens the manager must visit their office to validate
   orders. The audit now independently checks whether the manager's assigned
   historical figure owns a defined chair-room, reporting `present`,
   `missing`, `manager_missing`, `not_required` (below 20 citizens), or
   `unknown`. A missing office is a strong hypothesis for a mature fort, but the
   population and office state at the time of the original 61-order capture were
   not preserved; keep the diagnosis open until the audit is run on that save.

   **Live measurement, 2026-10-31 (`region1`, Erushavuz, 7 citizens, no manager
   office, `not_required`):** 46 orders imported from `library/basic` while the
   game was paused showed `validated=no` on every one. Two in-game days after the
   watchdog unpaused, 50 of 53 were validated (the 3 stragglers had just been
   created by `/surface2`); about nine days after load all 53 were, with 17
   active and the first order-driven jobs (MakeTool, MakeCage, MakeBucket,
   ConstructSplint) at workshops. So below 20 citizens validation works without
   an office, and needs only game time. **An audit taken while paused, or
   immediately after an import, will show every order unvalidated; that is not
   by itself a fault.** The original 61-order fort remains unexplained.
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
8. **Disposable live-smoke capture is implemented in PR #16; offline CI
   passed, and the first live run succeeded on 2026-10-31 against the operator's
   separate `region_smoke` copy (DF 0.47.05 linux64, DFHack 0.47.05-r8).
   `dfhack.getSavePath()` matched the exact selected folder, the map was loaded,
   all three read-only module reports completed, and the game was unpaused.
   The captured baseline was 7 citizens, 0 beds/bedrooms, 4 manager orders (all
   4 validated), 0 stalled jobs, 0 unmet requirements, and manager office
   `not_required`. The survival checklist reported 10 pass, 4 fail, 5 todo,
   0 warn. This proves the live diagnostic paths and active-save identity guard
   work; it does not prove future orders, furniture production, bedroom
   completion, or long-term survival. See
   [the live-smoke procedure](LIVE-SMOKE.md) for the recorded result.

### Cross-cutting hardening completed 2026-10-31

| Thing | Evidence |
| :-- | :-- |
| **Automated offline test gate** | `.github/workflows/tests.yml` runs `./tests/run_all.sh` on pushes and pull requests; the first workflow run passed |
| **Twitch claim persistence** | `ClaimRegistry` rolls back failed writes, fails closed on malformed JSON, preserves the damaged file, and keeps the in-game nickname intact when a release cannot be saved; regression tests pass in CI |
| **IPC contract validation** | Python rejects malformed or unknown protocol-2 snapshots without overwriting the last valid state; title-screen/live-fort and rejection cases pass in CI |
| **Bounded Twitch cooldowns** | Per-viewer cooldowns use monotonic time, expire opportunistically, and fail closed at a 2,048-login cap rather than evicting active viewers |
| **Save-selection safety** | The launcher refuses ambiguous save folders; a single fort can be selected explicitly; generated-world selection among multiple candidates remains a documented manual step |
| **Dreamfort catalogue contract** | Static test parses all 22 Lua plan entries and verifies each corresponds to an actual `#meta` or `#config` label in vendored `dreamfort.csv` |
| **Pinned Python runtime** | `requirements.txt` pins the TUI's direct and transitive dependencies to the versions exercised by Python 3.12 CI |
| **Subsystem health telemetry** | The Lua bridge distinguishes module-load, report, mapping and tick failures, retains last-success age, and the dashboard surfaces unhealthy/stale modules instead of silently omitting them |
| **High-risk checklist guidance** | The governance checklist no longer presents direct-memory squad creation as a routine fix; the operator is directed to a disposable fort and the roadmap's explicit risk note |
| **Manager-order diagnosis** | `antfarm_orders audit` reports tri-state validation/activity flags, stalled jobs/unmet inputs, and manager office readiness (including the 20-citizen threshold); stub tests prove it does not write protected flags |
| **Quarters furniture safety** | Furniture workorders omit the invalid material token, use the vendored `__reduce_amount` matcher to subtract equivalent open orders' `amount_left`, require `CR_OK` before reporting submission, and bed construction requires a free finished BED item; offline regressions guard these contracts |
| **Disposable live-smoke runner** | PR #16 merged; 11 fake-runner safety tests and full offline CI passed. PR #19 records a successful read-only run on a separately copied `region_smoke` save (DF 0.47.05 / DFHack 0.47.05-r8): 7 citizens, 4 validated orders, 0 stalled jobs, 0 unmet requirements. This verifies report paths and exact save identity only, not production completion or survival |
| **Brewing job priorities** | PR #20 replaces the nonexistent `Brew` job token with DFHack 0.47 `CustomReaction --reaction-name` filters for both plant-brewing reactions; a config regression test and CI pass guard it |
| **Dreamfort order-library retry** | PR #21 records an import as complete only after DFHack returns `CR_OK`; rejected imports remain pending and are retried after a later completed build step |
| **Autolabor command observability** | PR #22 checks `CR_OK` for MINE/CUTWOOD/HERBALIST/PLANT and publishes rejected command settings rather than claiming success; Lua tests cover return-code and thrown-error paths |
| **Post-job assignment gap** | PR #23 merged with passing CI; DFHack `workNow 2` pokes assignment when a dwarf finishes a job. It reduces post-job idle delay but does not create jobs or bypass labor eligibility |
| **A still with no brew orders** | Live `region1` sat at build step 4 with a finished still and `orders_done` empty: `library/basic` waits for step 5, which waits on surface digging. `antfarm_sustenance` now imports it once a still is finished, via `antfarm_blueprint.import_order_library()`, which also adopts brew orders already in the fort instead of duplicating 46 orders after a re-anchor. **Verified live:** imported on load, recorded in the plan, not re-imported at step 6; all 53 orders validated about nine in-game days after load |
| **The idle dwarves** | `prioritize -j` and `autolabor status` on the live fort: the only unclaimed work was 59 dig/stair jobs, so four dwarves had nothing they *could* do. Once step 5 placed workshops and stockpiles, every dwarf had a job |
| **A pick on the floor** | `tune_labour()` set each tool labour's minimum to 1, below DFHack's MINE default of 2; past the minimum autolabor only adds skilled dwarves or acts when 2+ are idle (`autolabor.cpp`, 0.47.05-r8). 110 dig jobs had one miner. Minimum now equals the tool count. **Verified live:** both picks held, two dig jobs worked |

These are code/CI checks, not live-fort verification. The military squad-creation
path and the other items in §2 remain subject to their stated live-game checks.

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
| **`antfarm_military` enlist / schedule** | Medium | **Enlist verified live 2026-11-01** against a squad the new driver created: target 1 soldier for 7 able citizens, the commander DF seats in position 0 counted, nobody extra drafted. Schedule `min_count` still unverified |
| **`antfarm_military create`** | — | **Resolved 2026-10-31: impossible in this build, now refuses.** See below |
| **Meeting-hall population sizing** | Low | Confirm the hall grows past the furniture box without swallowing corridors |
| **Grazing pasture + farmer workshop** | Medium | Confirm the zone is created on grass and the workshop lands adjacent |
| **Elven caravan detection** | Low | Needs an elven caravan on the map |

### The one to be careful with — resolved: it could never have worked

`antfarm_military create` built `df.squad` by hand, ported from df-ai's
`military_find_free_squad`. Tested 2026-10-31 on a **detached** squad that was
never linked into the world: `squad.schedule` is a
`vector<squad_schedule_entry[12]*>` (one contiguous twelve-month block per
alert, which df-ai allocated with a raw `malloc`), and DFHack 0.47 Lua rejects
every way of building one: `Cannot allocate arrays of non-primitive types`,
and inserting a table of twelve entries is refused. Each attempt would have
failed at the schedule step after consuming a squad id; the world-linking-last
ordering meant it never corrupted anything.

`enlist` writes the same three fields df-ai's `military_find_new_soldier` does
and only touches squads DF itself created.

**Resolved 2026-11-01: squads are created through DF's own military screen.**
`antfarm_ui`'s `squad` driver (a `start_driver()` coroutine, like petitions)
was mapped against the live screen and verified on `region_smoke`:
`D_MILITARY` opens `viewscreen_layer_militaryst` on page 0 with
`squads.list[i] == nil` for each leader position that has no squad;
the driver moves `layer_objects[0].cursor` to that slot, presses
`D_MILITARY_CREATE_SQUAD` (`in_create_squad` turns true: the uniform choice),
`SELECT`, and reads success only from the fort entity's squad count, then
`LEAVESCREEN`. Live: 0 → 1 squad, back on `dwarfmode/Default`, no driver
failure, the game ran on normally. `antfarm_military` asks for a squad when
soldier slots are below df-ai's one-in-five target and an appointed leader
(militia commander, captain...) has none -- only while a client drives the
fort; `antfarm_military create` / `antfarm_ui squad` run it once on the
operator's say-so. The first uniform entry is taken; choosing armour is still
manual.

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

### 3.2. Strange moods — implemented and verified live

`antfarm_mood.lua` (dispatched first in the server's subsystem list, every 60s)
reads each mood job's `job_items` exactly as DFHack's `showmood` does. It reports
needed / gathered / reachable / forbidden per requirement, unforbids just enough
when only forbidden matches exist, warns once when nothing in the fort matches,
and **places the workshop a mood needs when the fort has none of that kind**
(never a magma forge). The dashboard shows a `STRANGE MOOD` line.

**Verified 2026-10-31 on the disposable `region_smoke` copy:** `strangemood
-force -type fey` gave a jeweller mood in a fort with no Jeweler's workshop. The
module placed one, it was built and claimed, and the dwarf made *Osdin Giken, a
perfect brown zircon*. The live run also caught a bug the stub hid:
`dfhack.job.isSuitableItem` does not check item type, so a rough-gem demand had
matched 1086 stones; the module now checks type and subtype itself, and the stub
behaves like the real function.

**Second half implemented and verified live 2026-11-01** (same disposable copy).
When nothing in the fort matches a requirement, `antfarm_mood` escalates:

| Demand | Route | Live evidence |
| :-- | :-- | :-- |
| bone, shell, horn/hoof, ivory/tooth, pearl | ensure a butcher's workshop; use an animal already marked for slaughter, else mark one that yields the material -- never a pet, a war/hunting animal, or the last of its sex | (first bone mood resolved itself from a slaughtered yak before the route ran; the leather run below exercises the same marking path) |
| tanned leather | as above for SKIN, plus a tanner's workshop and a `CustomReaction` `TAN_A_HIDE` order (no `TanAHide` job exists in 0.47) | leatherworker mood: butcher's + tanner's placed, a spare dog marked, order validated and run, **2/2 leather gathered** |
| stone blocks, cut gems | `ConstructBlocks` / `CutGems` manager order with `__reduce_amount`, workshop placed if missing; gems name a material the fort holds as rough | offline only |
| anything else (e.g. *any bar* on a metal-less map) | **opt-in only** (`antfarm_mood createitem on`) and only under `createitem_below_ticks` of mood time left: `dfhack.items.createItem` at the dwarf's feet, cheapest acceptable material, in-game announcement | bar created, gathered at once, **artifact made** ("Teskomvumshar Sanad"); the run created iron, which led to the cheapest-material rule (copper) |

`report()` adds `days_left` and each requirement's `route`. Still open:
smelting for bar demands when ore and fuel exist (today only the opt-in conjure
serves them), cloth/thread, and logs.

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

`antfarm_quarters` is an interim survival path, not a replacement for Dreamfort's
full apartment phases. It submits manager workorder targets for beds, doors, chests and
cabinets using the vendored workorder script's `__reduce_amount` matcher, which
subtracts equivalent open orders' `amount_left` from the requested total before
creating a remainder.
It only queues a bed building when a free finished BED item exists. It
can place that bed in already-dug indoor floor and define/assign existing beds as
rooms. It does not yet prove that the full furniture set is completed, that every
room has correct extents/quality, or that the manager's workorders actually issue.
Dreamfort's `/apartments2` and `/apartments3` remain the curated housing phases
(steps 18 and 21). Live verification on a disposable fort is still required.

### 3.9. Phase 4 blueprint swap

Untouched. The 99 curated community blueprints are in
`game/blueprints/community/`, but nothing selects Raynard Whirlpool housing or
Andrelius Windmill Villas over Dreamfort's boxy quarters.

---

## 4. Easily-mistaken facts

* `MIN_FARMING_DEPTH = 2` is **deliberate**, not a typo for 3: the soil column
  on this embark is two levels deep, and a depth of 3 puts the farms in bare
  rock where no plot can be built without irrigating the floor to mud first.
  Do not "fix" it to 3.
* `fix/sleepers.lua` is a genuine DFHack script but **adventure-mode only** — it
  clears `ALARM_INTRUDER` on camp army controllers — so it is correctly *not*
  scheduled in `onMapLoad.init`. Do not add it.
* `community_blueprints/` is gitignored: it contains four nested `.git`
  directories from cloned repos, which git would record as broken submodule
  links. The curated, used copies live in `game/blueprints/community/`.

---

## 5. Suggested order

1. **Keep the live build moving.** The current fort (`region1`, Erushavuz) went
   from step 4 to step 7 on 2026-10-31 once brewing orders and both picks were
   in use. Digging is now limited by having two picks: more need a smelter and
   forge (Dreamfort `/industry2`, step 10) or the trade driver below.
2. ~~**Strange moods, second half**~~ — done 2026-11-01 (§3.2). Left: smelting
   for bar demands, cloth, logs.
3. ~~**Military-screen driver**~~ — done 2026-11-01 (§2). Left: picking a
   uniform instead of the first entry.
4. **Trade-screen driver** — the only path to iron on this map.
5. **Locations**, then flip the petition handler from decline to accept.
6. **Justice**, reusing the orders module's impossible-vs-not-yet logic.
7. **Targeted mining**, then the arbiter.
