# Disposable live-game smoke probe

This is an opt-in, aggregate-only diagnostic for an already-running DFHack
0.47.05 game. It is deliberately separate from `tests/run_all.sh` and is never
run by GitHub Actions.

It does **not** launch Dwarf Fortress, load a save, advance time, change pause
state, enqueue work, assign rooms, change nicknames, move the camera, or repair
anything. It invokes one Lua script, `antfarm_live_smoke`, which calls only:

- `antfarm_orders.audit()` — read-only manager-order flags, stalled jobs,
  unmet requirements and manager-office readiness.
- `antfarm_quarters.report()` — counts of citizens, beds, rooms, owners and
  furniture; no construction or assignment.
- `antfarm_checklist.report()` — aggregate of the checklist's documented
  read-only checks.

The Lua script writes a run-id-specific, aggregate-only report file into the DF
installation directory. It contains counts/statuses, year, pause state and DF /
DFHack versions; it does not include dwarf names, IDs, positions, thoughts or
other citizen profiles.

## Safety gates

All of the following are required before the wrapper will invoke DFHack:

1. The target must be a real existing fortress save with `world.sav` under
   `data/save/<region>/`. A generated-world-only `world.dat` is rejected.
2. The operator must manually place a marker file named
   `.antfarm-disposable-save` in that selected save folder. Its content must be
   exactly:
   `I UNDERSTAND THIS IS A DISPOSABLE ANT FARM TEST SAVE.`
3. The operator must pass both `--confirm-disposable` and
   `--confirm-loaded-save`. The second flag is an explicit attestation that
   this exact marked disposable save is currently loaded.
4. Both the DFHack wrapper and native `hack/dfhack-run` client must exist and
   be executable, and the Lua diagnostic must be installed in that DFHack
   scripts folder.

The wrapper cannot independently prove which save is currently loaded in the
game process. The second confirmation is therefore an operator attestation, not
an automatic loaded-region comparison. Check the title screen / loaded fortress
carefully before invoking it. Even with a mistaken attestation, the probe only
reads the currently loaded map and writes its report under the DF installation
directory; it does not mutate the save.

## Procedure

1. Close Dwarf Fortress. Make a **separate full copy** of a fortress save for
   testing; never use the only copy or your normal play save. Give the copied
   folder a distinct name such as `region_smoke`.
2. Confirm the copy contains `world.sav` and install the repository's
   `game/hack/scripts/antfarm_*.lua` scripts in that DF installation's
   `hack/scripts/` directory.
3. Create the marker only in the copied save:
   ```bash
   DF_DIR="/absolute/path/to/Dwarf Fortress"
   REGION="region_smoke"
   printf '%s\\n' 'I UNDERSTAND THIS IS A DISPOSABLE ANT FARM TEST SAVE.' \
     > "$DF_DIR/data/save/$REGION/.antfarm-disposable-save"
   ```
4. Start Dwarf Fortress normally and manually load **that copied region**.
   Do not use the Antfarm one-button launcher for this smoke step; the test is
   meant to observe a known, already-loaded disposable fortress.
5. From the repository root, run:
   ```bash
   python3 tools/live_smoke.py \
     --df-dir "$DF_DIR" \
     --region "$REGION" \
     --confirm-disposable \
     --confirm-loaded-save
   ```
   The wrapper contacts the local DFHack RPC server and has a 45-second default
   timeout. It does not start the game if no RPC listener is available.
6. Read the reported `antfarm_live_smoke_<run-id>.txt` file in the DF
   installation directory. Keep the report with the test notes. It is
   git-ignored when the installation is this repository's `game/` folder.

The runner fails closed on missing markers, path traversal, symlinked save
folders, missing `world.sav`, missing binaries/scripts, a DFHack timeout,
mismatched report run IDs, a title screen with no map loaded, or a failed
required module report.

## What this does not prove

A successful report means the three read-only report paths executed against a
loaded map. It does **not** prove a manager order will validate, that the
carpenter will produce furniture, that a construction will complete, that beds
will become properly assigned bedrooms, or that the fortress survives over
time. Those require a separately controlled live test with observations before
and after each intentionally mutating action. Do not turn this probe into an
automatic repair or add it to CI.
