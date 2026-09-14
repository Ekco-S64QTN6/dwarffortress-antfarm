# Code review, 2026-09-13 — findings and outcomes

A full-codebase review was run against the pre-restructure tree (Claude Sonnet
4.6). It reported 16 bugs, 8 security/robustness concerns, 5 memory/resource
issues, 7 missing features and 5 design concerns.

Every finding was checked against the code and against this DFHack build before
being acted on. **Two were wrong** and are recorded below with the evidence, so
nobody "fixes" them later. The rest were real and are fixed.

Paths below use the current layout (`antfarm/`, `game/`); the review predates
the rename.

---

## Rejected — verified incorrect

**B-08: `list_cmd_files` double-prefixes the directory.**
Claimed that on the `listdir_recursive` fallback, `e.path` is relative to
`CMD_DIR` and the consumer re-prefixes it. It is not.
`dfhack.filesystem.listdir_recursive(dir, depth, include_prefix)` takes a third
argument, and `antfarm_server.lua` passes `false`, which strips the prefix —
the same call `internal/quickfort/list.lua` and `gui/blueprint.lua` make. The
names are already bare.
*Action:* no behavioural change. A `basename` strip was added anyway as cheap
insurance against a build that ignores the flag, since the failure mode would be
every command silently dropped.

**B-15: `antfarm_overlay.lua` starts the server a second time.**
Claimed `reqscript('antfarm_server')` executes the script and re-runs `start()`.
It does not. `reqscript` → `dfhack.script_environment(name, true)` → runs the
script with `module=true`, and `antfarm_server.lua` ends with
`if dfhack_flags and dfhack_flags.module then return end` **before** it parses
its arguments. The script body never reaches `start()`.
*Action:* none.

---

## Fixed

### Correctness

| Finding | Fix |
| --- | --- |
| B-01 bootstrap TOCTOU, and `bootstrapped` never reset | Check-and-set moved under `self.lock`; reset in `stop()`, so a restarted engine bootstraps again |
| B-02 concurrent probes clobber each other | The server keys probes by unit id and publishes a `probes` list; `_probe` matches its own request |
| B-03 `active_unit_id` written without the lock | Written under `self.lock` like every other shared field |
| B-04 `_handle_rotation` held the lock across file I/O | Split into `_choose_target` (under the lock) and the client call (outside it) |
| B-05 auto-unpause could stay suppressed forever | Replaced wholesale — see *Pause classification* below |
| B-06 `find_shortest_path` used `list.pop(0)` | `collections.deque` + `popleft`. Kept, not deleted: `remove_node`/`prune_to` are new callers' neighbours and the function is a documented part of the graph API |
| B-07 probe TTL mixed `os.time()` with `time.time()` | Both sides now use `wall_ms()`/`time.time()` |
| B-09 `utf8_from_codepoint` was BMP-only | Handles 4-byte sequences, and `extract_json_string` now combines surrogate pairs |
| B-10 `_STRESS_HISTORY` evicted by insertion order | `OrderedDict` LRU keyed on last sample |
| B-11 lore cache wiped all 256 entries at once | LRU, one entry at a time |
| B-12 `spawn_term` broke on a path containing `'` | `shq()` quoting helper |
| B-13 `cmd_fort` reached into `claims.by_user` | `ClaimRegistry.count()` |
| B-14 / D-02 three different interest scores | One `score_citizen()`; the dashboard now shows the number the Director steers by |
| B-16 `.capitalize()` on a possibly-`None` emotion | `_thought_words()`, plus Rich markup escaping on all game text |
| D-01 hysteresis 40 vs the documented 150 | 150, overridable with `ANTFARM_HYSTERESIS` |
| D-03 every roster departure announced as a death | Deaths must be corroborated by an announcement; everything else is `CitizenDeparted` and is not announced |
| D-04 `stairs_top` read but never written | Stored by `survey()` |
| D-05 `auto foo` enabled auto mode | Strict `on`/`off` |

### Security and robustness

| Finding | Fix |
| --- | --- |
| S-01 plugin directory prepended to `sys.path` forever | `importlib.util.spec_from_file_location` under an `antfarm_plugins.` namespace. A plugin named `json.py` can no longer shadow the stdlib |
| S-02 substring matching in `!claim` | Resolution is restricted to the unclaimed pool and compared by id |
| S-03 unbounded slow-command threads | Bounded `ThreadPoolExecutor` (4 workers, 32 queued) that sheds load |
| S-04 OAuth token kept in `self.cfg` | Popped into `self._token` at construction; the config dict no longer holds it, and `config/` moved out of the importable package |
| S-05 `unit_id` type not validated | `ClaimRegistry.set` coerces to `int` and refuses anything else |
| S-06 lever keywords matched `"Pantry Door"` | `door`, `lock`, `raise`, `bridge`, `seal` retired; `antfarm_lever list` shows what a rename would re-enrol |
| S-07 status reader assumed the working directory | Path passed as `argv[1]` |
| S-08 `antfarm_worlds.txt` not ignored | Added to `.gitignore` |

### Memory and resources

| Finding | Fix |
| --- | --- |
| M-01/M-02 `stress_history` and `interest_events` grew forever | `_prune_departed()` on every roster update; an empty roster is treated as "no information", not a mass departure |
| M-03 failed connects leaked a socket every 15s | `finally: s.close()` |
| M-04 hot-reload dropped events between unsubscribe and subscribe | Subscribe the replacement first, then unsubscribe the old one |
| M-05 `stop()` did not join the poll watchdog | Joined with a timeout |
| F-01 dead dwarves inflated graph centrality | `remove_node()` / `prune_to()`; non-dwarf history is kept |

### Missing features

* **F-03** — moderator-only commands are rejected before the cooldown is charged.
* **F-04** — `!unclaim` / `!release`, which also clears the in-game nickname.
* **F-05** — quickfort output is parsed and the affected-tile count checked. A
  step that does nothing is retried and then recorded as a warning instead of
  silently advancing.
* **F-06** — the watchdog, build stalls and build warnings all appear on the
  dashboard header and in `start_antfarm.sh` status.
* **F-07/S-08** — output files gitignored.
* **F-02** — bootstrap acknowledgement: *not implemented as specified*. The
  bootstrap now waits for a live fortress and the blueprint driver refuses to
  run while the game is not on the map, which addresses the failure the finding
  describes; a command-level ack protocol was not added.

---

## Beyond the review

The review looked at the code as written. The larger problem was what the code
did not attempt: an unattended fort stops on a dialog box and nothing pressed
the key. That work — `game/hack/scripts/antfarm_ui.lua`, the guided build's
`autostart`, verification and stall detection — is described in the README
(*Keeping the game running*) and `AGENTS.md` 6.7. Much of it is ported from
[df-ai](https://github.com/BenLubar/df-ai).

## Verification

None of this could be tested before; `tests/` did not exist. It does now:
`tests/df_stub.lua` fakes `df`/`dfhack` (viewscreen stack, popup queue,
announcement log, a sparse map, and a `gui.simulateInput` that records
keystrokes), and `./tests/run_all.sh` runs syntax checks plus 110 unit tests
across the watchdog, the guided build and the Python engine.
