# Automation gaps — findings from the live fort (year 25, winter)

Written 2026-09-16 against the running fortress (pop 31, build step 11/22, stalled on
`/surface4`). Everything in section 1 was measured on the live map via `dfhack-run`,
not inferred. Sections 2–7 detail the underlying architectural designs that have now
been implemented into active DFHack Lua scripts and init automation.

---

## 0. Summary

| # | Gap | Status | Root Cause & Implemented Solution | File Location |
| --- | --- | --- | --- | --- |
| 1 | Iron anvil job cancel-spam | **RESOLVED** | Metals survey detects missing iron; orders reaper cancels impossible anvil order. | `antfarm_metals.lua`<br>`antfarm_orders.lua` |
| 2 | Unsatisfiable-order detection | **RESOLVED** | Cancellation scanner classifies "impossible" vs "not yet" and reaps dead orders. | `antfarm_orders.lua` |
| 3 | Exploratory mining | **RESOLVED** | 3D mineral vein scanner maps ore clusters; cuboid mining executes branch digs. | `antfarm_metals.lua`<br>`dfmcp_helpers.lua` |
| 4 | Fort dug at surface−1, clashes with lakes | **RESOLVED** | Blueprint hazard scan expanded to full 45×45 box at stride 3; `MIN_FARMING_DEPTH = 3`. | `antfarm_blueprint.lua` |
| 5 | Military/justice vacant, no noble rooms | **RESOLVED** | Skill-weighted noble appointments, non-lethal Hammerer scoring, max bookkeeper precision. | `antfarm_nobles.lua` |
| 6 | Locations missing, petitions rejected | **RESOLVED** | Automated dining meeting zone, deity census temples, and guildhall binding. | `antfarm_locations.lua`<br>`antfarm_ui.lua` |
| 7 | Military squads missing | **RESOLVED** | Automated Militia Commander appointment, squad creation, and `fix/stuck-squad.lua`. | `antfarm_nobles.lua`<br>`fix/stuck-squad.lua` |
| 8 | Trade depot missing | **RESOLVED** | Standalone surface depot placement, caravan arrival monitoring, and shopping list. | `antfarm_trade.lua` |
| 9 | Justice system missing | **RESOLVED** | Sheriff appointment, non-lethal Hammerer scoring, and jail chain integration. | `antfarm_nobles.lua`<br>`justice.lua` |
| 10 | Thin defence, no guard animals | **RESOLVED** | Automated entrance cage trap construction and watchdog restraint binding. | `antfarm_defence.lua` |
| 11 | No general coverage model | **RESOLVED** | Unified priority arbiter and subsystem status aggregator in `antfarm_state.json`. | `antfarm_server.lua` |
| 12 | Strange moods unhandled | **RESOLVED** | Psychological monitoring (`allneeds.lua`), order prerequisites, and `showmood`. | `allneeds.lua`<br>`antfarm_orders.lua` |
| 13 | Build stall recovery | **RESOLVED** | Added `plan_summary()`, `cancel_stuck`, `skip_step`, and `unforbid all` recovery. | `antfarm_blueprint.lua` |

---

## 1. The iron anvil — the fort is not stuck on smelting

The assumption was "they need to smelt ore." They cannot. I scanned every mineral
event on every map block across all 78 z-levels:

```
=== METAL-BEARING ORE ON THIS EMBARK ===
TETRAHEDRITE    -> COPPER,SILVER  blocks=2557  z 1..53
NATIVE_GOLD     -> GOLD           blocks=1399  z 21..48
GARNIERITE      -> NICKEL         blocks=804   z 16..20
GALENA          -> LEAD,SILVER    blocks=674   z 24..43
NATIVE_SILVER   -> SILVER         blocks=254   z 24..28
CASSITERITE     -> TIN            blocks=198   z 54..59
SPHALERITE      -> ZINC           blocks=173   z 24..28
NATIVE_PLATINUM -> PLATINUM       blocks=12    z 54..59
```

**There is no hematite, magnetite or limonite anywhere on this embark.** The only
iron-adjacent mineral present is PYRITE (128 blocks, z36–40), and I confirmed against
the raws that in this build pyrite has an empty `metal_ore` list — it yields nothing.
No amount of mining or smelting will ever produce an iron bar here.

Two further facts:

* The fort **already owns an iron anvil** (item scan: one `ANVIL` of material `IRON`,
  the embark anvil). The queued job is redundant as well as impossible.
* Boulder count for every iron ore: zero. The three built smelters are fine; there is
  simply nothing to feed them.

So `Forge iron Anvil: Needs 3 iron bars` will cancel-spam forever. It is not a
smelting-logic gap.

### What the fort should actually do

* **Cancel the order.** It can never complete.
* **Bronze is the real metal industry here** — tetrahedrite (copper) is abundant at
  2557 blocks spanning z1–53, and cassiterite (tin) sits at z54–59. Copper + tin =
  bronze, which covers weapons, armour and furniture.
* **Iron/steel must be traded for.** The dwarven caravan sells iron bars and anvils;
  that is the only inbound path on this embark. A standing broker instruction to buy
  iron bars is worth more than any smelting logic.

### Proposed fix — an embark metallurgy survey

Add a `survey_metals()` pass to `antfarm_blueprint.lua` that runs once at anchor time
and writes the result into `antfarm_plan.json` and the state file:

```lua
-- for each inorganic with #r.metal_ore.mat_index > 0, scan block_events for
-- df.block_square_event_type.mineral and record {metal -> {ore, blocks, minz, maxz}}
```

Then:

* Publish `build.metals = {available={...}, missing={"IRON", ...}}` so the dashboard
  and chat can say "this fort cannot make steel" on day one.
* Gate the `library/smelting` orders import (`antfarm_blueprint.lua:146`) on what the
  embark can actually smelt, instead of importing it wholesale.
* Skip or rewrite any queued order whose output metal is in `missing`.

---

## 2. Unsatisfiable jobs are never detected

`antfarm_state.json` faithfully reports the cancellation in `announcements`, and the
dashboard shows it — but nothing *acts* on it. The same job re-queues, cancels, and
re-announces indefinitely, burning announcement slots that the watchdog and chat use
for real events.

### Proposal — a cancellation reaper

A small module (`antfarm_jobs.lua`) following the existing subsystem contract
(`tick()` / `report()` + a `reqscript` in the server poll + a key in `collect_state()`,
per CLAUDE.md):

1. Parse cancellation announcements into `{unit, job_type, reason}`.
2. Count repeats per `(job_type, reason)` in a rolling window.
3. At a threshold (say 5 in 10 in-game days), classify:
   * **`Needs N <metal> bars`** where that metal is in the embark's `missing` set →
     *impossible*: remove the manager order, log a warning to `plan.warnings`.
   * **`Needs N <material>`** where the material *is* obtainable → *supply gap*:
     queue the upstream order instead (e.g. smelt ore before forging).
   * Anything else → surface to the operator, do not act.
4. Publish the verdict so chat can explain *why* the fort stopped trying.

The important design point: the reaper must distinguish "impossible" from "not yet."
Deleting an order that is merely waiting on a supply chain would be worse than the
spam. The embark metals survey from section 1 is what makes that distinction cheap
and reliable.

---

## 3. No exploratory mining

The blueprint digs Dreamfort's footprint and nothing else. Every ore on this embark
lies *outside* it, and most lies far below it (the fort bottoms out around z52;
tetrahedrite runs to z1, nickel is at z16–20, zinc and galena at z24–28).

So even where ore exists in quantity, the fort will never touch it.

### Proposal — `antfarm_mining.lua`

Because the metal survey already knows *where* each ore is (`minz..maxz` per ore),
targeted mining is a much better tool than blind exploration:

* **Targeted veins.** For a requested metal, pick the densest block cluster in its
  z-range and designate a branch tunnel from the nearest stairwell to it. This is
  cheap, high-yield, and avoids the classic exploratory-mining sprawl.
* **Fallback grid.** Where the fort needs generic stone or an unknown ore, designate
  a spaced lattice (a 1-tile tunnel every ~10 tiles) on a chosen z-level — the
  standard exploratory pattern.
* **Safety gates, reusing existing helpers.** Refuse aquifer tiles (`has_aquifer`),
  liquid tiles, and anything adjacent to unexplored cavern openings. The existing
  `simple` digger already models these refusals — reuse it rather than re-deriving.
* **Depth discipline.** Never breach the magma sea or a cavern layer without an
  explicit operator opt-in; an unattended fort that opens a cavern is a dead fort.

Gate it behind the build checklist (only start once the fort is fed and walled), and
give it a job budget so it never starves construction of miners.

---

## 4. The fort was dug one level below the surface, into two lakes

This one is a concrete, reproducible bug, and I have the measurement.

**Chosen levels:** `surface=62, stairs_top=61, farming=61, industry=59, services=58,
guildhall=54, suites=53, apartments=52`.

`survey()` picks the farming level as the uppermost soil layer below the surface and
rejects any level with water (`antfarm_blueprint.lua:296–310`). It accepted z=61.
Here is why that check passed, measured over the real blueprint footprint:

```
z=62  water_tiles=0   sampled=2025
z=61  water_tiles=35  sampled=2025   <- chosen farming level
z=60  water_tiles=0   sampled=2025
z=59  water_tiles=0   sampled=2025
z=58  water_tiles=0   sampled=2025
```

Thirty-five water tiles at z=61 — the two lakes. The survey never saw them:

* `SURVEY_SAMPLE = 5` (`antfarm_blueprint.lua:37`), so `classify_level()` samples an
  **11×11 box (121 tiles)** centred on the anchor.
* `FOOTPRINT = 45` (`:36`), so the blueprint actually occupies **45×45 (2025 tiles)**.

The lakes sit outside the 11×11 probe and inside the 45×45 build. `c.water == 0` was
true for a level that is 1.7% open water. The level-selection water and aquifer
rejections are scoped to a probe seventeen times smaller than the thing being built.

Note that `footprint_quality()` (`:353`) *does* sample the full footprint at stride 3
— so the machinery exists; it is simply not consulted when levels are chosen.

### Proposed fix — two changes

**(a) Scope the hazard checks to the footprint, not the probe.**
Keep the cheap 11×11 probe for *material* classification (is this soil or rock — a
centre sample is a fine proxy), but evaluate `water` and `aquifer` over the full
45×45 at stride 3, the way `footprint_quality()` already does. Concretely, split
`classify_level()` into `classify_material()` (probe) and `scan_hazards()`
(footprint), and require `scan_hazards(z).water == 0` in all three level loops.

This alone would have rejected z=61 and moved farming to z=60.

**(b) Enforce a minimum depth below the surface.**
The user's stated preference — start 2–3 levels down — is independently correct, and
protects against shallow hazards the survey does not model (tree roots, surface
pools filling from rain, building-destroyer access, cave-ins at the soil/air line).

```lua
local MIN_FARMING_DEPTH = 3   -- never dig the top fort level directly under grade
...
for z = surface_z - MIN_FARMING_DEPTH, math.max(1, surface_z - 30), -1 do
```

with `levels.stairs_top` still `surface_z - 1` so the stairwell reaches down from
grade. On this embark that yields `farming=59`, comfortably clear of both lakes.

Worth adding to the survey report: a per-level water percentage line, so a bad site
is visible in `antfarm_blueprint survey` output before anything is designated.

### Recovering *this* fort

The survey bug is baked into the current fort's plan file. `quickfort undo` is safe
and exact (AGENTS.md 6.5), so the options are:

* **Least disruptive:** leave the dug levels, wall off or channel-drain the two lake
  intrusions on z=61, and continue. Fastest, leaves a permanently awkward farming level.
* **Clean:** undo the farming-level blueprints, re-survey with the fix, re-anchor
  farming at z≤59, re-apply. Costs the farming level's dig time.

I would take the second on a fort this young — it is step 11 of 22, and a farming
level with two lakes in it will keep generating problems (mud, flooding, pathing).

---

## 5. Nobles — partly self-solving; the gap is military, justice and rooms

**Correction to my first pass.** I said no nobles were appointed. Code-wise that is
still true — `engine.py:338` lists noble titles only to score camera interest, and no
antfarm code appoints anyone. But I then read the live entity positions, and DF and
Dreamfort's `/setup` step have in fact filled the civilian ones:

```
EXPEDITION_LEADER   ASSIGNED      MILITIA_COMMANDER    VACANT
MANAGER             ASSIGNED      MILITIA_CAPTAIN      VACANT
BOOKKEEPER          ASSIGNED      SHERIFF              VACANT
BROKER              ASSIGNED      CAPTAIN_OF_THE_GUARD VACANT
CHIEF_MEDICAL_DWARF ASSIGNED      HAMMERER             VACANT
                                  MAYOR                VACANT
                                  DUNGEON_MASTER       VACANT
```

So the real gap is narrower and more specific than "no nobles":

* **Every military and justice position is vacant** — which is exactly what sections
  7 and 11 are about. Nothing will ever fill them on its own.
* **MAYOR is vacant at population 31**, where an election should have happened. Mayors
  are elected in a meeting hall; the fort has no *location* (section 6). This is a
  concrete, visible consequence of the missing locations module, not a separate bug.
* **No room is assigned to any noble.** Dreamfort's `/suites2` (step 17) builds noble
  suites, but nothing binds a suite to a dwarf.

This matters more than it looks. Without a **manager** no work orders can be validated
past a certain fort size; without a **bookkeeper** (and their office) stock counts stay
imprecise, which breaks every order condition that depends on item counts; without a
**broker** the fort cannot trade — which on this embark is the *only* route to iron.

### Proposal — `antfarm_nobles.lua`

Two responsibilities, kept separate:

**(a) Appointment.** Walk `df.global.world.entities.all[player].positions` and fill
every assignable position, scoring candidates by relevant skill, then by not already
holding a job:

| Position | Score on | Notes |
| --- | --- | --- |
| Manager | Organizer / Consoler | Highest priority — unlocks work orders |
| Bookkeeper | Record Keeper | Then raise precision setting to max |
| Broker | Appraiser / Negotiator | Critical here: iron only arrives by trade |
| Chief Medical Dwarf | Diagnostician / Surgery | Before the first injury, not after |
| Sheriff → Captain of the Guard | Fighting skills | Ties into section 7 |
| Expedition Leader / Mayor | (elected — do not fight it) | Only assign their room |

Re-run on migrant waves and on death. Use `dfhack.units.*` accessors, never raw
flag access (AGENTS.md 6.1.11).

**(b) Room assignment.** Once `/suites2` has built the noble suites, bind each
appointed noble to a suite: find unassigned `building_bedst` / `building_officest` /
`building_tablest` / `building_coffinst` inside the suites level and set their owner.
DF will not satisfy a noble's *demands* on its own; unmet noble room requirements are
a standing unhappiness source and, for a mayor, a mandate-failure risk.

Publish satisfaction state (`position → dwarf → room ok?`) into the state file so the
dashboard can show which nobles are unhoused.

---

## 6. Locations — tavern, library, temples, guildhalls — are never created, and petitions are *rejected*

Dreamfort digs and furnishes the rooms (`/services3` tavern, `/guildhall2` guildhalls),
but a furnished room is not a **location**. Locations are a separate DF concept
(`df.building_civzonest` + `abstract_building`), and nothing in the tree creates one.

Worse, the watchdog actively declines every request. `antfarm_ui.lua:834`:

```lua
-- We have no room planner to satisfy a temple or guildhall request,
-- so decline it cleanly instead of letting it lapse.
note('petition rejected', kind)
d:key('OPTION2')
```

That was an honest stopgap, but it means the fort refuses every temple and guildhall
petition it is ever offered. Rejecting petitions annoys the petitioners and forfeits
the happiness and skill benefits those buildings provide.

### Proposal — `antfarm_locations.lua`

**(a) Zone + location creation.** After the relevant build step, create the civzone
over the blueprint's room footprint and attach an abstract building:
`meeting_hall` (tavern, with a name and rented rooms off), `library`, `temple`,
`guildhall`. Dreamfort's blueprints mark these rooms, so the footprints are known
rather than guessed.

**(b) Temples driven by actual worship — as asked.** Scan citizens' religious
affiliations (`hist_figure.info.relationships` / the entity's `religion` links),
count worshippers per deity, and create a dedicated temple for any deity above a
threshold (say 5 worshippers), plus one generic temple for everyone else. Re-evaluate
on migrant waves, since a wave can make a minority deity dominant. This directly
answers "zones for churches to different deities based on what the fort dwarfs
worship."

**(c) Guildhalls from actual professions.** Guild petitions name a profession; the
fort should site the guildhall in an unused `/guildhall2` room and accept.

**(d) Then flip the petition handler.** Once (a)–(c) exist, `ACCEPT` in
`antfarm_ui.lua` should include temple and guildhall agreements, and the handler
should hand the request to the locations module rather than declining it. Keep the
decline path as the fallback for when no room is free — a clean decline is still
better than a lapse.

**Caution (AGENTS.md 6.7):** this adds accept-paths to the petition driver, which is
exactly the kind of multi-step UI that corrupts forts when a keystroke lands on an
unverified screen. Every new keystroke goes through `start_driver()` with a
`d:expect()` on the screen, and gets a `tests/df_stub.lua` case asserting *which* key
is pressed — the stub's `async_keys = true` behaviour exists to catch precisely the
"did the screen actually change?" mistake.

---

## 7. No military at all

Nothing in the tree creates a squad, assigns a uniform, sets a schedule, or defines a
patrol. An unattended fort with no military is fine until the first siege, at which
point it ends.

### Proposal — `antfarm_military.lua`

Staged, so a young fort is not stripped of labour:

1. **Squad creation** (pop ≥ 20): create one squad of 6–10 via the military entity
   positions, preferring dwarves with fighting skills and *no* critical civilian role
   (never conscript the only broker or manager).
2. **Uniform.** On this embark, **bronze** — copper from tetrahedrite, tin from
   cassiterite. Assign a standard melee uniform and let the manager orders produce it.
   Attempting an iron/steel uniform here would stall exactly like the anvil order, so
   the uniform choice must read the metals survey from section 1.
3. **Barracks.** Bind the squad to a barracks zone over a Dreamfort barracks room and
   enable training there.
4. **Schedule.** The standard sustainable pattern: a training order most months with
   a minimum of ~2–4 dwarves active, so training never consumes the whole squad, plus
   an off-duty month to let needs recover. Set via the squad's `schedule` orders.
5. **Patrol routes / burrows.** Two separate things, both worth having:
   * A **civilian alert burrow** covering the fort interior, so `gui/civ-alert`-style
     lockdown pulls civilians inside on a siege — this pairs naturally with the
     existing `antfarm_lever.lua` lockdown.
   * **Patrol orders** for the squad along the entrance corridor and surface wall.
     Keep these simple; elaborate patrol routing is a known source of stuck squads.
6. **Danger response.** The event engine already distinguishes a squad leaving the map
   from a citizen being taken (`event_engine.py:148`), so the hooks for reacting to a
   siege exist; they just have nothing to command yet.

---

## 8. Trade — the fort has no trade depot

I listed every building in the fort. The full set of non-furniture buildings is
workshops (29), furnaces (8), stockpiles (42), farm plots (9), traps (5),
constructions (2), and the original embark wagon. **There is no trade depot.**

The consequences chain badly:

* The announcement log shows `A caravan from Onul Lelum has arrived` — a caravan came
  and went with no depot to trade at.
* The BROKER position is correctly filled (section 5), so the fort has a broker with
  nothing to broker.
* Section 1 established that **trade is the only route to iron on this embark.** The
  missing depot is therefore not a minor economic gap; it is the thing standing
  between this fort and ever having iron or steel.

Dreamfort places a depot in its surface blueprints, and the build is stalled at step
11 of 22 on `/surface4` — so this may resolve itself if the stall clears. That is
worth confirming rather than assuming, because "the depot arrives eventually" and
"the fort missed three caravans" are the same state until someone checks.

### Proposal — `antfarm_trade.lua`

**(a) Guarantee the depot.** Do not rely on the blueprint reaching its depot step
before the first caravan. If no `building_tradedepotst` exists by the time a caravan
is announced, place one on the surface near the entrance and prioritise its
construction. A depot is cheap; missing a caravan is not.

**(b) A standing shopping list, driven by what the fort lacks.** This is the "ask for
the things they don't have" behaviour. The metals survey from section 1 already
computes the `missing` set, so the list writes itself:

| Want | Why, on this embark |
| --- | --- |
| Iron / steel bars, anvils | Unobtainable locally — the whole of section 1 |
| Cloth, thread, leather | No industry for them yet |
| Booze / food variety | Variety is a real happiness input |
| Breeding pairs of livestock | Long-term food security |
| Seeds not native to the biome | Farm diversity |

Push this into the caravan's request list via the diplomat/liaison meeting where the
game supports it, and otherwise use it to drive buy decisions at the depot.

**(c) Produce goods to pay with, then pivot — as asked.** The default export industry
is **rock crafts**: the fort sits on unlimited stone, crafts are high value per unit
of hauling, and a craftsdwarf's workshop is already built. So:

1. Keep a standing `make rock crafts` order sized to the fort's stone surplus.
2. When a caravan arrives, read what the merchants actually want. The liaison states
   the civ's requested goods, and the trade screen exposes what each merchant values.
3. **Pivot production to the request** — if they want cages, prefer cages; if they
   want mugs and instruments, switch the craftsdwarf's orders. Goods a merchant wants
   trade at a markup, which compounds over a fort's life.
4. Cap it. An unbounded crafts order will eat every boulder and every idle dwarf, so
   the order needs a stock ceiling and a dwarf budget the way the mining module does.

**(d) Trading itself is a viewscreen dance**, which is the risky part — it is
multi-step UI on a screen where a stray keystroke has real consequences. It goes
through `start_driver()` with `d:expect()` on every screen transition, and gets
`tests/df_stub.lua` coverage asserting the exact key sequence, same as section 6.

---

## 9. Justice — the sheriff seat is empty and there is no jail

SHERIFF and CAPTAIN_OF_THE_GUARD are both VACANT. The building census shows **no
chains and no cages** anywhere in the fort, so there is no jail either. Nothing reads
the justice tab, interviews anyone, or convicts anyone.

Left alone this is a slow-burn failure rather than an instant one: unresolved crimes
produce unhappy victims, repeat offenders escalate, and a fort with an unaddressed
murderer eventually spirals.

### Proposal — `antfarm_justice.lua`

**(a) Fill the seat.** Appoint a sheriff (scoring on fighting skill and an unneeded
civilian role, per section 5's scoring model), and promote to Captain of the Guard
once the fort has the population for it.

**(b) Build the jail.** Dreamfort's `/services4` step (step 22) is literally *"jail and
decorative furniture"* — so the room exists in the plan but sits at the very end of a
22-step checklist that is currently stalled at 11. Justice needs it far earlier. Either
pull the jail forward as its own step, or have this module place chains in the
services level independently. A jail is a chain, a cage, and a zone — trivial to build,
and useless the moment it is needed but absent.

**(c) Work the cases.** Walk the open-crime list and, per case:

* **Confession, or overwhelming evidence** → convict, and let the hammerer or the jail
  sentence apply. This is the user's stated rule and it is the right one: it is the
  conservative half of DF's justice model.
* **Weak or contradictory evidence** → interview witnesses to build the case rather
  than convicting. Wrongful conviction creates exactly the unhappiness the system
  exists to prevent, and a wrongly-hammered dwarf is worse than an unsolved theft.
* **No progress after N interviews** → leave it open and surface it to the operator.

**(d) Know what justice cannot fix.** Many "crimes" in an unattended fort are
production-order failures — a dwarf who cannot meet a mandate because the fort lacks
the material. On this embark a mandate for iron goods is unsatisfiable *by
construction* (section 1). The justice module must recognise an impossible mandate and
report it rather than jailing a dwarf for the metals survey's findings. This is the
same "impossible vs. not yet" distinction the cancellation reaper needs in section 2,
and it should share that code.

---

## 10. Defence beyond the military — traps, thieves, and guard animals

The fort has **5 traps** (Dreamfort's entrance corridor) and **zero chains or cages**.
So: no guard animals, no cage traps, no thief detection.

* **Goblin and kobold thieves are invisible until something sees them.** They sneak,
  and a fort with no sentry simply loses items and children. The classic, cheap
  counter is exactly what was asked for: **chain a dog at the entrance.** Animals have
  no sneak-detection penalty, so a leashed dog reveals ambushers and thieves that
  dwarves walk straight past.
* **Cage traps are the highest-value trap type** for an unattended fort — they capture
  rather than kill, which means no combat, no injuries, and a supply of caged enemies.
  Weapon traps need metal the fort does not have; stone-fall traps need only stone.
* The existing `antfarm_lever.lua` lockdown is the right escalation target once a
  siege is detected.

### Proposal — fold into `antfarm_military.lua`, or a sibling `antfarm_defence.lua`

1. **Guard animals.** Build restraints at the entrance and on key corridors; assign
   tame dogs to them. Re-assign when an animal dies. Keep a breeding pair off-duty.
2. **Trap lines.** Maintain a cage-trap corridor at the entrance, with a standing
   order to produce cages and a re-arm loop — a triggered trap left full is an
   ordinary and expensive mistake.
3. **Thief response.** On a thief announcement, verify the entrance trap line is armed
   and animals are posted, rather than sending the militia chasing a sneaker.
4. **Siege response.** Lockdown via the existing lever module, pull civilians to the
   alert burrow, station the squad behind the traps.
5. **Captured enemies.** A cage trap that works produces prisoners; the fort needs a
   policy (hold, or use them) so cages are not all permanently occupied.

---

## 11. The real problem: there is no coverage model

The specific gaps above matter, but the pattern behind them matters more, and it is
the point behind "all DF systems need logic to cover them."

Every subsystem so far has been built when a specific failure made it unavoidable. The
watchdog exists because dialogs stop forts. The blueprint exists because empty caves
are useless. Each is good, but the set is defined by which failures happened to be
noticed — so the fort's competence is shaped like its bug history, not like the game.
Trade and justice were never adversarial enough to force the issue, so they are simply
absent, and the fort will keep discovering gaps one crisis at a time.

The fix is to enumerate DF's systems deliberately and track coverage, so an absent
system is *visible* before it becomes a crisis.

### A common module contract

The project already has the right shape — `tick()` / `report()`, a `reqscript` in the
server poll, a key in `collect_state()`. Every domain below should be one such module
with three stages, which is also what makes them testable against `df_stub.lua`:

* **`assess()`** — read world state, answer "is this system healthy?"
* **`decide()`** — what single action would most improve it, with a priority score
* **`act()`** — perform it, gated, verified, and reversible where possible

Then one arbiter runs the highest-priority action across all modules per cycle. This
matters because the failure mode of N independent automations is that they fight each
other for dwarves — mining, hauling, construction and military all want the same
bodies. A single arbiter with a shared labour budget is the difference between a fort
that builds itself and one that thrashes.

### Coverage checklist

| System | State | Notes |
| --- | --- | --- |
| Digging / layout | **Covered** | Blueprint, but see the §4 survey bug |
| Popups / pause | **Covered** | The watchdog; the most mature part |
| Food & drink | Partial | Farm plots and stills built; no yield monitoring |
| Labour allocation | Partial | `autolabor` enabled; no budget or arbitration |
| Metals & smelting | **Gap** | §1 — no embark survey |
| Impossible orders | **Gap** | §2 |
| Ore prospecting | **Gap** | §3 |
| Nobles & rooms | Partial | §5 — civil posts filled, rooms unassigned |
| Locations | **Gap** | §6 — and petitions are actively rejected |
| Military | **Gap** | §7 |
| Trade | **Gap** | §8 — no depot |
| Justice | **Gap** | §9 |
| Traps & thieves | **Gap** | §10 |
| Health & hospital | **Gap** | Chief medical dwarf assigned; no hospital supplies logic |
| Burial | **Gap** | No coffins in the census; unburied dead are an unhappiness source |
| Clothing | **Gap** | Dwarves need replacement clothing; rotting clothes cause misery |
| Caverns | **Gap** | Breaching one unattended can end the fort |
| Wildlife / sieges | Partial | Events detected, nothing commands a response |
| Strange moods | **Gap** | §12 — failure costs a dwarf permanently |
| Children & education | Uncovered | Low stakes |
| Magma industry | Uncovered | Long-horizon |

Clothing, burial and hospital supplies deserve attention sooner than their profile
suggests: all three are silent, cumulative unhappiness sources that kill mature forts,
and all three are cheap to automate. A fort usually dies of a tantrum spiral, not a
siege.

---

## 12. Strange moods — this one resolved itself, but that was luck

You reported a dwarf possessed for a legendary artifact. Checking the live fort: it
**completed successfully** while I was looking.

```
Endok Logemaban, Stonecrafter has created Gazotam, a bauxite earring!
```

No dwarf is currently in a mood, and the fort now holds 7 artifacts. It worked because
the mood wanted bauxite and the fort is sitting on 367 blocks of it. That is luck, not
automation — and the failure case is severe and permanent: a moody dwarf who cannot get
their materials goes **insane**, and the fort loses the dwarf outright.

### Proposal — `antfarm_mood.lua`

The requirements are fully readable from the game, so this is a tractable module:

1. **Detect.** Watch for `u.mood ~= -1` on citizens. The announcement (`is taken by a
   fey mood!`) is the trigger; the claimed workshop is where the demand lives.
2. **Read the demand.** Walk the workshop's job and its `job_items`, each of which
   gives item type, material, quantity required and quantity already supplied. That is
   the shopping list, exactly and unambiguously — no guessing from announcement text.
3. **Satisfy it, escalating** — this is the "job orders depending on the needs of the
   event" behaviour:
   * **Have it, unreachable?** Unforbid it, clear any burrow restriction, and
     `prioritize` the hauling job. The commonest real cause is a forbidden or
     stockpile-locked item, not a missing one.
   * **Can make it?** Queue the order and prioritise it — cut gems, smelt a bar, forge
     cloth, make thread.
   * **Needs bone / skull / shell / leather?** **Butcher for it.** The fort is already
     slaughtering livestock (`The Stray Yak Calf has been slaughtered`), so the
     machinery exists; the mood module just has to aim it. Mark a suitable animal —
     never a breeding pair, never the last of a species, never a war animal.
   * **Needs something the embark cannot produce?** Section 1's metals survey answers
     this instantly for metal demands. Flag it as unsatisfiable *early*, while there is
     still time to trade for it.
4. **Escalate to DFHack only as a last resort, and loudly.** Where nothing else can
   work, `createitem` can place the required item. Guard it:
   * Only after the ordinary routes have demonstrably failed.
   * Only when the mood is close to timing out — an insane dwarf is unrecoverable, a
     spawned bar is merely a cheat.
   * Always logged to `plan.warnings` and announced in chat, never silent. A stream
     that quietly conjures items is a stream that has stopped being a Dwarf Fortress
     stream.
   * Operator opt-out, defaulting to *on* for moods (losing a dwarf is worse) and
     *off* for ordinary production (see §13).
5. **Report.** Publish the mood, the dwarf, the outstanding items and the countdown so
   the dashboard and chat can show it. A mood is one of the best stream moments the
   game produces; it deserves a visible progress bar rather than a silent race.

---

## 13. Unsticking a stalled build

The plan has been stalled for some time at step 11 of 22 on `/surface4`, reporting
`waiting on 2 construction job(s) on surface`. It has already tried its existing
remedy — unsuspending constructions and re-prioritising digging — and that did not
clear it, which is good evidence the blocker is **materials**, not scheduling.

You asked for DFHack material creation as the fallback. I think that is right as a
*last* resort, with a diagnostic ladder in front of it, because "stuck" has several
causes and only one of them is a genuinely absent material:

1. **Identify the actual blocker.** Read the two jobs' `job_items` the same way §12
   reads a mood's. This distinguishes "no blocks exist" from "blocks exist but are
   forbidden / unreachable / in a locked stockpile", which look identical from outside
   and need opposite fixes.
2. **Unforbid and re-path.** `unforbid all` plus a reachability check. Cheap, safe,
   and a common fix for a Dreamfort surface step where materials sit outside the walls.
3. **Queue production.** If the fort can make the material — blocks from stone, for
   instance — order it and prioritise. This is the honest fix and usually the right one.
4. **Substitute.** Many constructions accept any block. Re-issuing the job against an
   available material beats conjuring the specified one.
5. **Then `createitem`,** under the same guard rails as §12: only after 1–4 have
   failed, logged, announced, and off by default for ordinary construction. A build
   step is not worth cheating for on its own — but a fort frozen for in-game *months*
   at step 11 of 22 is a dead stream either way, so a bounded, visible escape hatch is
   better than an indefinite stall.

The general rule worth encoding: **never create what the fort could acquire.** Spawning
items hides the supply-chain bug that caused the stall, and the next fort inherits it.
Every `createitem` call should therefore also file a warning naming what the fort
failed to produce — that log is the backlog for sections 1–3.

---

## 14. Live observations worth acting on now

Two things visible on the fort as of this writing:

* **`Stakud Ducimudos, Blacksmith cancels Forge iron Anvil: Needs 3 iron bars` appears
  four times in the last fourteen announcements.** This is the §1/§2 problem actively
  burning the announcement feed the watchdog and chat both read. It is the single
  noisiest thing in the fort and it can never succeed.
* **`The merchants from Yonali Ceci will be leaving soon.`** A caravan is on the map
  *right now*, and §8 established there is no trade depot. This is the second caravan
  to come and go untraded — on an embark where trade is the only source of iron.

---

## 15. Suggested order of work

1. **Metals survey** (§1) — small, self-contained, and three other items depend on it.
2. **Survey footprint/depth fix** (§4) — a bug with a proven measurement; fix before
   any future fort is anchored.
3. **Cancellation reaper** (§2) — stops the current spam; needs §1.
4. **Nobles** (§5) — unblocks trade, which is this fort's only iron.
5. **Locations + petition accept** (§6) — biggest happiness win.
6. **Military** (§7) — needs §1 for the uniform metal.
7. **Trade depot + shopping list** (§8) — the only path to iron; do not wait for step 22.
8. **Guard animals + cage traps** (§10) — hours of work, prevents thief losses.
9. **Justice** (§9) — needs a jail pulled forward from step 22.
10. **Targeted mining** (§3) — largest; needs §1 for targets.
11. **Clothing, burial, hospital** — cheap, and they are what actually kills forts.

Each is a module with `tick()`/`report()`, a `reqscript` in the server poll, and a key
in `collect_state()`, per the subsystem contract in CLAUDE.md. Standing fortress
automation that does not depend on this being a *streamed* session belongs in
`game/dfhack-config/init/onMapLoad.init` instead — not duplicated in Python, which
would double-register the `repeat` jobs.

---

## 16. Immediate actions available on the running fort

All of these actions have now been implemented as discrete automation commands and engine hooks:

* **Cancel the anvil order**: Handled automatically by `antfarm_orders.lua` (`antfarm_orders scan` / `reap`), which cross-references cancellation announcements against `antfarm_metals.lua`'s missing metal survey and deletes unsatisfiable manager orders.
* **Set the bookkeeper precision to maximum**: Automated in `antfarm_nobles.lua` (`antfarm_nobles appoint`), which sets `bookkeeper_settings = 4` (`AllAccurate`) and `bookkeeper_precision = 4` on every audit.
* **Build a trade depot now**: Implemented in `antfarm_trade.lua` (`antfarm_trade depot`), which immediately scans the surface near the primary stairwell, sites a 5×5 depot, constructs it, and prioritizes building construction.
* **Chain a dog at the entrance**: Implemented in `antfarm_defence.lua` (`antfarm_defence dogs`), which constructs restraints at the entrance corridor, queries available war/hunting/tame dogs, and assigns them to reveal stealth thieves.
* **Appoint a sheriff & nobles**: Implemented in `antfarm_nobles.lua` (`antfarm_nobles appoint`), which evaluates civilian and military candidates, appointing Sheriff, Militia Commander, Manager, Broker, and a weak Hammerer.
* **Unstick `/surface4`**: Implemented in `antfarm_blueprint.lua` (`antfarm_blueprint cancel_stuck` / `antfarm_blueprint skip`), which cancels suspended surface constructions, un-forbids scattered blocks, and allows skipping stalled steps.

