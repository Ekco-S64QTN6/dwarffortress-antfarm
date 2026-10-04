# What a fort needs to survive

A systematic replacement for noticing problems by watching the game.

Everything here is checkable with one command:

```bash
cd game && ./dfhack-run antfarm_checklist          # all of it, grouped
./dfhack-run antfarm_checklist fail                # only what is wrong
./dfhack-run antfarm_checklist survival            # one group
```

It reads state and never changes the fort, so it is safe to run at any time.

---

## 1. Why this exists

Every problem found on the first few automated forts was found by a human
watching the screen and noticing something off:

| What was noticed | What it actually was |
| :-- | :-- |
| "dwarves are getting thirsty, I don't see a still" | the still lives in Dreamfort step 7, gated behind digging the farming level |
| "a bunch of dwarves standing around doing nothing" | 4 dwarves assigned to mining, 2 picks on the embark |
| "dwarves are still hanging outside getting rained on" | the only meeting area was the embark default, on the surface |
| "people inside are sleeping on the floor" | 0 beds; Dreamfort builds them at step 18 of 22 |
| "the fort appears stuck on an iron anvil" | no iron ore on the embark at all |
| "game just closed/crashed" | an unsafe write to DF's order-validation bits (AGENTS.md 6.1.12) |

Each one was cheap to detect and invisible until somebody looked. That is the
gap this closes: the checks are the things a human would look for, written down
and run on demand.

---

## 2. The checklist

Grouped, roughly in dependency order. `antfarm_checklist` reports each as
**PASS**, **FAIL** (critical and broken), **TODO** (wanted, not yet), or
**WARN** (cannot tell yet).

### Survival — a fort dies without these

| Check | Passes when | Fixed by |
| :-- | :-- | :-- |
| drink stock | ≥ 2 drinks per citizen | `antfarm_sustenance all` |
| booze production | a still exists, plants on hand, brew orders queued | `antfarm_sustenance workshops` |
| food stock | ≥ 2 edible items per citizen | `antfarm_sustenance all` |
| a bed for everyone | beds ≥ citizens | `antfarm_quarters beds` |
| indoor meeting area | a meeting zone that is **not** outside | `antfarm_locations hall` |
| plant gathering | a gathering zone with shrubs in it | `antfarm_sustenance gather` |

Rain is a real stress source in 0.47, and an outdoor meeting area means the whole
fort stands in it. Sleeping on the floor is a standing, cumulative penalty. Both
are cheap to fix and were being ignored for twenty of the build's twenty-two steps.

### Infrastructure

| Check | Passes when | Fixed by |
| :-- | :-- | :-- |
| farm plots | at least one plot built | the build at `/farming2` |
| tools match the labour | miners ≤ picks on hand | `antfarm_sustenance labour` |
| trade depot | a depot exists | `antfarm_trade depot` |
| stockpiles | at least one | the build at `/surface2` |

"Tools match the labour" is the one that is easy to miss: autolabor will happily
assign four miners on an embark carrying two picks, and the surplus stand still.

### Governance

| Check | Passes when | Fixed by |
| :-- | :-- | :-- |
| key officers appointed | manager, bookkeeper, broker, chief medical dwarf all filled | `antfarm_nobles appoint` |
| military exists | at least one squad | `antfarm_military create` then `enlist` |
| justice | a sheriff (or captain) and somewhere to hold a prisoner | `antfarm_nobles appoint` (the jail is still unimplemented) |

### Health

| Check | Passes when | Fixed by |
| :-- | :-- | :-- |
| burial capacity | a coffin exists, or there are no ghosts | `burial`, `antfarm_autoslab check` |
| water source | a well or a water-source zone | dig a cistern (unimplemented) |

### Hazards

| Check | Passes when | Fixed by |
| :-- | :-- | :-- |
| no impossible work orders | nothing queued that the embark cannot make | `antfarm_orders reap` |
| defence at the entrance | cage traps or guard animals | `antfarm_defence traps` / `dogs` |
| lockdown lever | a lever named gate/drawbridge/portcullis exists | name one in game |
| usable metals | the embark yields some martial metal | `antfarm_trade` for what it does not |

---

## 3. Priority order — the part that is still missing

Knowing *what* a fort needs is not the same as knowing *when*. The checks above
are a set; a fort is built in a sequence, and the sequence matters more than any
single item.

The community worked this out years ago. The canonical reference is
**Captain Duck's tutorial series** (2012) — the videos that taught a generation of
players a working opening, in order, with reasons. That series is the thing to
match the subsystems against: not a list of features but a *sequence*, where each
step exists because the one before it made it possible.

**Dreamfort is the other encoding** of the same idea — its twenty-two steps are a
curated build order, which is exactly why this project drives it rather than
hand-rolling a digger (`docs/fortress-build.md`).

The two differ in an important way. Captain Duck's order is what a *player* does,
including all the improvising a player does without thinking about it: a couple of
farm plots and a still in the first season, a dormitory thrown up early, booze
checked constantly. Dreamfort's order is what a *finished fort* looks like being
built cleanly, and it defers those improvisations in favour of doing them properly
later. Automation that follows Dreamfort alone inherits the deferral without
inheriting the player who was covering for it.

What has gone wrong so far is not Dreamfort's order but **what the automation does
around it**:

* Dreamfort's order assumes a player watching, who will notice that the fort has
  no booze at step 7 and go fix it by hand. Unattended, nobody does.
* Several essentials sit very late in that order — beds at step 18, the jail at
  step 22 — because a human player would have improvised them much earlier.
* The gates are per-level and correct, but a gate held by a two-pick bottleneck
  holds everything behind it.

So the rule this project now follows: **survival items are never gated.**
`antfarm_sustenance` places a still, a kitchen and a farmer's workshop regardless
of what step the build is on; `antfarm_quarters` places beds in whatever indoor
space has been dug; `antfarm_locations` will take a bare dug room as a meeting
area rather than leave the fort in a field. The blueprint still provides the
*good* versions of all of these later; the module provides a *survivable* version
immediately.

### Still open

**Nothing matches the subsystems against a known-good opening order.** The
survival rule above (never gate the essentials) is a backstop, not a plan. Working
through Captain Duck's opening season and asserting that each step either happens
or is deliberately skipped would turn "the fort did not die" into "the fort was
played well".

There is no **arbiter**. Mining, hauling, construction, military and gathering
all draw from the same dwarves, and nothing ranks them. Today the ordering is
implicit: the subsystem dispatch list in `antfarm_server.lua` runs
`antfarm_sustenance` first, because a thirsty fort outranks everything, and each
module gates itself on a wall clock. That is a priority *ordering*, not a
priority *budget* — two subsystems can still both decide to consume every idle
dwarf.

Designing that budget is the last significant piece; see
[`REMAINING-WORK.md`](REMAINING-WORK.md) §3.7.

---

## 4. Adding a check

`game/hack/scripts/antfarm_checklist.lua` holds a single `CHECKS` table. Each
entry is:

```lua
{group = 'survival', critical = true, name = 'drink stock',
 fix = 'antfarm_sustenance all',
 check = function()
    -- return ok, detail
    -- ok == true  -> PASS
    -- ok == false -> FAIL (critical) or TODO (not critical)
    -- ok == nil   -> WARN: cannot tell yet
 end},
```

Checks must be read-only and must not raise — the runner wraps each in `pcall`,
but a check that throws tells you nothing. Prefer reading another module's
`report()` over re-deriving state, so there is one definition of each fact.
