# df-ai (reference copy — not executed)

Four files from [BenLubar/df-ai](https://github.com/BenLubar/df-ai), the Ruby
autonomous-fortress AI that predates this project. **Nothing here runs.** DFHack's
Ruby plugin is not loaded, and these are kept purely as a reference
implementation to port from.

| File | What it is worth reading for |
| --- | --- |
| `population.rb` | `update_military`, `military_find_new_soldier`, `military_find_free_squad` — the squad creation, enlistment and training-schedule logic ported into `game/hack/scripts/antfarm_military.lua` |
| `plan.rb` | Room planning and `getsoldierbarrack` / `freesoldierbarrack` |
| `stocks.rb` | Standing production targets and the "what does the fort lack" loop |
| `main.rb` | The top-level cadence the whole thing runs on |

CLAUDE.md's rule for the watchdog applies here too: **port from df-ai rather than
reinvent.** It drove unattended 0.47 forts for years, and every piece of it
encodes a failure someone already hit. `antfarm_ui.lua` is largely a port of its
`pause.cpp`/`ai.cpp`; `antfarm_military.lua` is a port of the military half of
`population.rb`.

Note that a port is not a test: the squad-creation half could not be ported.
df-ai mallocs each alert's twelve-month schedule block, which DFHack 0.47 Lua
cannot allocate, so `antfarm_military create` now refuses. See
`docs/ROADMAP.md` §2.
