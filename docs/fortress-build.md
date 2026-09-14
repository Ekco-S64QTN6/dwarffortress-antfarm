# Guided fortress construction

`antfarm_blueprint` builds a real fortress instead of digging empty rooms. It
drives **Dreamfort**, the community-tuned blueprint set that ships with DFHack,
and walks its official build checklist step by step.

Dreamfort is a complete fort: trap-corridor entrance, farming, industry,
services, guildhalls, noble suites and apartments — with the furniture,
stockpiles, zones and room assignments included, not just the digging.

---

## Why this instead of a hand-written digger

A digger produces caves. Dwarves need beds, doors, tables, workshops,
stockpiles, a well and defined rooms before a fort functions. Dreamfort encodes
all of that, plus traffic designations and the ordering that keeps miners
working one level at a time. Reusing it means the fort is laid out the way an
experienced player would lay it out.

---

## Quick start

In the DFHack console, with a fort loaded:

```
antfarm_blueprint survey      # what the geology under the cursor looks like
antfarm_blueprint here        # anchor the fort at the cursor
antfarm_blueprint auto on     # build it, step by step, as each gate clears
```

Or drive it from the dashboard: `b` applies the next step, `B` toggles auto
mode. Chat can query progress with `!build`.

---

## How the site is chosen

Dreamfort's underground levels are **not** independently placeable. Its
`/dig_all` blueprint is anchored once, on the industry level, and digs
everything below at fixed offsets — straight out of `dreamfort.csv`:

```
/industry1  #>  /services1  #>4  /guildhall1  #>  /suites1  #>  /apartments1 repeat(down 5)
```

So only three levels are free choices; the rest follow:

| Level | How it is chosen |
| --- | --- |
| surface | highest **walkable** level — the floor dwarves stand on, not the first solid level below it |
| farming | uppermost **soil** layer below the surface, skipping aquifers |
| industry | first layer that is ≥80% **rock** with 12 clear levels beneath it |
| services, guildhall, suites, apartments | industry −1, −5, −6, −7 (and four more) |

`survey` reports all of this plus a *footprint usable* percentage — how much of
Dreamfort's ~45×45 surface area is free of water and cliffs. Below 85% it warns
you; Dreamfort wants a big flat site.

> Getting the surface wrong by one level is fatal and silent: the whole fort is
> designated one z-level inside the ground, nothing connects to where the dwarves
> are, and they stand idle forever next to thousands of unreachable tiles. The
> survey therefore looks for walkable ground (`FLOOR`/`RAMP`/`STAIR_*`/...), not
> merely "not a wall" — open air is not a wall either.

Aquifer and water tiles are rejected at every stage. If there is no soil layer,
or no rock column deep enough, the survey refuses and says why rather than
anchoring somewhere that will not work.

---

## How steps are gated

Each step declares what must be quiet before it may run:

* `dig` — no outstanding dig designations on the fort's levels
* `build` — the above, plus no outstanding construction jobs
* `none` — safe to run straight after the previous step

Auto mode checks every 10 seconds and applies the next step when its gate opens,
with a one-minute floor between steps so jobs have a chance to be picked up.
This mirrors the human instructions in Dreamfort's checklist ("run when the
farming level has been dug out").

Before any step that needs materials, the orchestrator runs `quickfort orders`
to queue the manager orders, and afterwards runs `prioritize ConstructBuilding`
so the workshops it just placed actually get built. As the fort matures it
imports the `basic`, `furnace`, `smelting` and `rockstock` orders libraries.

---

## Commands

| Command | Effect |
| --- | --- |
| `antfarm_blueprint survey` | report geology and the levels it would pick |
| `antfarm_blueprint here` | anchor at the cursor and survey |
| `antfarm_blueprint status` | progress, chosen levels, and the current gate |
| `antfarm_blueprint list` | the whole 22-step plan |
| `antfarm_blueprint next [--force]` | apply the next step (`--force` ignores the gate) |
| `antfarm_blueprint auto on\|off` | apply steps automatically |
| `antfarm_blueprint orders` | queue manager orders for the upcoming step |
| `antfarm_blueprint reset` | forget progress; designations are left alone |
| `antfarm_blueprint simple [-d N]` | standalone digger — no Dreamfort, works anywhere |

Progress is kept in `game/antfarm_plan.json` so it survives reloads,
and is published in the Antfarm state file for the dashboard and chat.

---

## `simple` mode

`antfarm_blueprint simple` is the original standalone digger: a central
stairwell, a trunk corridor, meeting hall, stockpile bay, workshops and bedroom
rows. It only writes dig designations and refuses aquifer, liquid and open
tiles. Use it on embarks where Dreamfort's footprint will not fit, or when you
want a quick starter hole with no material requirements.

---

## Caveats

* Dreamfort assumes a reasonably flat embark with soil over rock. Check the
  `survey` output before committing.
* Auto mode is gated on *observable* state, not on understanding. It will
  happily keep building while a siege is on. The lockdown levers
  (`antfarm_lever`) are the defence, not the build orchestrator.
* Some Dreamfort steps print manual follow-ups (linking levers to bridges,
  assigning an office to a specific noble). Those messages appear in the DFHack
  console and are not automated.
* Labor assignment is deliberately left alone — see `AGENTS.md` 6.2.4 and the
  comments in `dfhack-config/init/onMapLoad.init`.
