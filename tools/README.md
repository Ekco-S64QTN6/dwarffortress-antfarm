# Bundled utilities

Four companion programs, each with a launcher script beside it. Run one
directly, or pick it from option 6 of `../start_antfarm.sh`.

| Launcher | Program | What it is |
| --- | --- | --- |
| `DwarfTherapist.sh` | `bin/dwarftherapist` | Labour and skill management with a far better interface than the game's |
| `LegendsBrowser2.sh` | `legendsbrowser` | Web viewer for an exported Legends archive |
| `SoundSense-RS.sh` | `soundsense-rs/soundsense-rs` | Reads `../game/gamelog.txt` and plays music and effects for what happens |
| `AnnouncementWindow.sh` | `announcement/run.py` | Filtered announcement feed in a separate window |

These used to sit in `LNP/Utilities/` and be launched from the PyLNP GUI. That
launcher has been removed — it rewrote the game's init files and kept undoing
the crash fixes documented in `AGENTS.md` section 6.2 — so the scripts now live
next to the binaries they start.

Two path constraints, both load-bearing:

* **`bin/` and `share/` must stay siblings.** Dwarf Therapist runs in portable
  mode and resolves its data as `../share` relative to its own executable.
* **`legendsbrowser.properties` points at `../game`** and is read from this
  directory, so `legendsbrowser` must be started with `tools/` as its working
  directory. The launcher does that.

Each program is by its own authors and under its own licence.
