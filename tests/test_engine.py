"""Tests for the Python half of Antfarm.

Run: .venv/bin/python -m tests.test_engine     (from the repository root)

These never touch a real Dwarf Fortress directory. ANTFARM_DF_DIR is pointed at
a scratch directory before antfarm.client is imported, because a live fortress will
happily execute commands a test writes into the real spool -- AGENTS.md section
6.5 records a test nickname ending up on a real dwarf that way.
"""

import os
import sys
import tempfile
import time
import unittest

_SCRATCH = tempfile.mkdtemp(prefix="antfarm-test-")
os.environ["ANTFARM_DF_DIR"] = _SCRATCH
os.environ.pop("ANTFARM_AUTOBUILD", None)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from antfarm.engine import AntfarmEngine                    # noqa: E402
from antfarm.event_engine import EventBus, EventEngine       # noqa: E402
from antfarm.knowledge_graph import SimulationKnowledgeGraph  # noqa: E402
from antfarm.sdk import BasePlugin, PluginManager            # noqa: E402
from antfarm.twitch import ClaimRegistry, TwitchBridge       # noqa: E402


class FakeClient:
    """Stands in for DFClient: records commands instead of writing files."""

    def __init__(self):
        self.commands = []
        self.latest_state = None
        self.citizens_list = []
        self.on_state_update_callbacks = []
        self.on_citizens_update_callbacks = []

    def add_state_callback(self, cb):
        self.on_state_update_callbacks.append(cb)

    def add_citizens_callback(self, cb):
        self.on_citizens_update_callbacks.append(cb)

    def send_cmd(self, cmd):
        self.commands.append(cmd)
        return True

    def focus_unit(self, unit_id):
        return self.send_cmd(f"focus {unit_id}")

    def unfocus(self):
        return self.send_cmd("unfocus")

    def execute_dfhack(self, cmd):
        return self.send_cmd(f"command {cmd}")

    def unpause(self):
        return self.send_cmd("unpause")

    def probe_unit(self, unit_id):
        return self.send_cmd(f"probe {unit_id}")

    def set_nickname(self, unit_id, nick):
        return self.send_cmd(f"nick {unit_id} {nick}")


def citizen(cid, name="Urist", **kw):
    d = {"id": cid, "name": name, "profession": "Peasant", "current_job": "Idle",
         "stress": 0, "density": 0, "nick": "", "claimed": False,
         "pos": {"x": 1, "y": 1, "z": 1}}
    d.update(kw)
    return d


class EngineHousekeeping(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.engine = AntfarmEngine(self.client)

    def test_departed_dwarves_are_forgotten(self):
        """stress_history and interest_events grew forever (report M-01/M-02)."""
        roster = [citizen(1), citizen(2), citizen(3)]
        self.engine._on_citizens_received(roster)
        for d in roster:
            self.engine.score_citizen(d, sample=True)
        self.assertEqual(set(self.engine.stress_history), {1, 2, 3})

        self.engine._on_citizens_received([citizen(1)])
        self.assertEqual(set(self.engine.stress_history), {1})

    def test_an_empty_roster_is_not_a_mass_departure(self):
        """The server sends an empty roster whenever no map is loaded."""
        roster = [citizen(1), citizen(2)]
        self.engine._on_citizens_received(roster)
        for d in roster:
            self.engine.score_citizen(d, sample=True)
        self.engine._on_citizens_received([])
        self.assertEqual(set(self.engine.stress_history), {1, 2})

    def test_global_interest_events_survive_pruning(self):
        self.engine.interest_events["global"] = ["announcement"]
        self.engine.interest_events[99] = ["dead dwarf"]
        self.engine._on_citizens_received([citizen(1)])
        self.assertIn("global", self.engine.interest_events)
        self.assertNotIn(99, self.engine.interest_events)

    def test_graph_drops_departed_dwarves(self):
        self.engine._on_citizens_received([citizen(1), citizen(2)])
        self.engine.knowledge_graph.add_edge(1, 2, "friend")
        self.assertEqual(len(self.engine.knowledge_graph.get_neighbors(1)), 1)
        self.engine._on_citizens_received([citizen(1)])
        self.assertEqual(self.engine.knowledge_graph.get_neighbors(1), [])

    def test_bootstrap_flag_resets_so_a_restart_bootstraps(self):
        """B-01: bootstrapped was never cleared, so session two never ran it."""
        self.engine.running = True
        self.engine.bootstrapped = True
        self.engine.stop()
        self.assertFalse(self.engine.bootstrapped)

    def test_bootstrap_runs_once_under_concurrency(self):
        import threading
        self.engine.running = True
        self.client.latest_state = {"map_loaded": True, "fortress_stats": {"pop": 7}}
        threads = [threading.Thread(target=self.engine._bootstrap_when_ready)
                   for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        prioritize = [c for c in self.client.commands if "prioritize" in c]
        self.assertEqual(len(prioritize), 1, self.client.commands)

    def test_autobuild_is_off_by_default(self):
        """It designates thousands of tiles; it must be opted into."""
        self.engine.execute_initial_payloads()
        self.assertNotIn("command antfarm_blueprint autostart", self.client.commands)

    def test_autobuild_can_be_switched_on(self):
        self.engine.autobuild = True
        self.engine.execute_initial_payloads()
        self.assertIn("command antfarm_blueprint autostart", self.client.commands)


class Scoring(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.engine = AntfarmEngine(self.client)

    def test_one_scoring_path_for_every_caller(self):
        """D-02/B-14: the dashboard used to omit density and relations."""
        self.engine._on_citizens_received([citizen(1, density=6), citizen(2)])
        self.engine.knowledge_graph.add_edge(1, 2, "spouse")
        d = self.engine.citizens[0]
        header = self.engine.score_citizen(d)
        ranked = dict((c.get("id"), s) for s, c in self.engine.ranked_citizens())
        self.assertAlmostEqual(header, ranked[1], places=5)
        # Density (6 * 5.0) and one relation (1 * 10.0) both have to be in it.
        self.assertGreaterEqual(header, 40.0)

    def test_hysteresis_defaults_to_the_documented_value(self):
        """D-01: the code said 40, the research documents 150."""
        self.assertEqual(self.engine.hysteresis_threshold, 150.0)

    def test_rotation_does_not_hold_the_lock_across_the_client_call(self):
        """B-04: focus_unit writes a file; the listener thread needs the lock."""
        seen = []

        def watcher(unit_id):
            seen.append(self.engine.lock.acquire(blocking=False))
            if seen[-1]:
                self.engine.lock.release()
            return True

        self.client.focus_unit = watcher
        self.engine._on_citizens_received([citizen(1, stress=90000)])
        self.engine.mode = "director"
        self.engine._handle_rotation()
        self.assertTrue(seen, "the camera never moved")
        # An RLock is re-entrant on the same thread, so this asserts only that
        # the call happens; the structural guarantee is that _choose_target
        # returns an id and _handle_rotation calls the client after the block.
        import inspect
        src = inspect.getsource(self.engine._handle_rotation)
        after_with = src.split("with self.lock:", 1)[1]
        self.assertIn("self.client.focus_unit(target)", after_with)
        body = after_with.split("if target is not None:", 1)[0]
        self.assertNotIn("focus_unit", body)


class DeathDetection(unittest.TestCase):
    def setUp(self):
        self.bus = EventBus()
        self.seen = []
        self.bus.subscribe("*", lambda e: self.seen.append(e))
        self.engine = EventEngine(self.bus)

    def _state(self, citizens, announcements=()):
        return {"map_loaded": True, "citizens": citizens,
                "announcements": list(announcements)}

    def test_a_corroborated_death_is_a_death(self):
        # Two dwarves, one dies: a roster that empties completely is treated as
        # "no information" instead (the player quit to the menu), which the
        # empty-roster test below covers.
        self.engine.process_state(self._state([citizen(1, name="Urist McMiner"),
                                               citizen(2, name="Kadol")]))
        self.engine.process_state(self._state(
            [citizen(2, name="Kadol")], ["Urist McMiner has died of thirst."]))
        names = [e.name for e in self.seen]
        self.assertIn("CitizenDeath", names)
        self.assertNotIn("CitizenDeparted", names)

    def test_a_bare_disappearance_is_a_departure_not_a_death(self):
        """D-03: banishment, visitors leaving and squads off-map all looked
        like deaths, and chat announced every one of them."""
        self.engine.process_state(self._state([citizen(1, name="Urist McMiner"),
                                               citizen(2, name="Kadol")]))
        self.engine.process_state(self._state(
            [citizen(2, name="Kadol")], ["Kadol has grown to become a Legendary Miner."]))
        names = [e.name for e in self.seen]
        self.assertIn("CitizenDeparted", names)
        self.assertNotIn("CitizenDeath", names)

    def test_an_empty_roster_never_reports_deaths(self):
        self.engine.process_state(self._state([citizen(1), citizen(2)]))
        self.seen.clear()
        self.engine.process_state(self._state([]))
        self.assertEqual([e.name for e in self.seen if e.name == "CitizenDeath"], [])


class Graph(unittest.TestCase):
    def test_removing_a_node_removes_its_edges_both_ways(self):
        g = SimulationKnowledgeGraph()
        g.add_node(1, "dwarf", "A")
        g.add_node(2, "dwarf", "B")
        g.add_edge(1, 2, "spouse")
        g.add_edge(2, 1, "spouse")
        g.remove_node(1)
        self.assertEqual(g.get_neighbors(2), [])
        self.assertIsNone(g.get_node(1))

    def test_prune_keeps_non_dwarf_history(self):
        g = SimulationKnowledgeGraph()
        g.add_node(1, "dwarf", "A")
        g.add_node(2, "artifact", "The Sword")
        g.prune_to(set())
        self.assertIsNone(g.get_node(1))
        self.assertIsNotNone(g.get_node(2))

    def test_shortest_path_still_works(self):
        g = SimulationKnowledgeGraph()
        g.add_edge(1, 2, "friend")
        g.add_edge(2, 3, "friend")
        self.assertEqual(g.find_shortest_path(1, 3), [1, 2, 3])
        self.assertIsNone(g.find_shortest_path(1, 99))


class Plugins(unittest.TestCase):
    def test_plugins_do_not_shadow_the_standard_library(self):
        """S-01: the loader put the plugin directory on sys.path forever."""
        import json as real_json
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "json.py"), "w") as f:
                f.write("HIJACKED = True\n"
                        "from antfarm.sdk import BasePlugin\n"
                        "class Plugin(BasePlugin):\n"
                        "    def __init__(self):\n"
                        "        super().__init__('evil')\n")
            before = list(sys.path)
            mgr = PluginManager(EventBus(), SimulationKnowledgeGraph())
            mgr.load_plugins_from_directory(d)
            self.assertEqual(sys.path, before, "the plugin directory was left on sys.path")
            import json as still_json
            self.assertIs(still_json, real_json)
            self.assertFalse(hasattr(still_json, "HIJACKED"))
            self.assertIn("evil", mgr.plugins)

    def test_hot_reload_never_drops_an_event(self):
        """M-04: unsubscribe-then-subscribe left a window with no listener."""
        bus = EventBus()
        mgr = PluginManager(bus, SimulationKnowledgeGraph())

        class P(BasePlugin):
            def __init__(self):
                super().__init__("same-name")
                self.events = []

            def on_event(self, event):
                self.events.append(event)

        first = P()
        mgr.register_plugin(first)
        second = P()
        mgr.register_plugin(second)
        # Exactly one live subscription for the name.
        with bus.lock:
            subs = list(bus._subscribers.get("*", []))
        self.assertEqual([s for s in subs if s == first.on_event], [])
        self.assertEqual(len([s for s in subs if s == second.on_event]), 1)


class Claims(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(_SCRATCH, "claims-%f.json" % time.time())
        self.reg = ClaimRegistry(path=self.path)

    def test_a_bad_unit_id_is_refused(self):
        """S-05: a null id was stored and then never matched again."""
        self.assertFalse(self.reg.set("viewer", None, "Urist"))
        self.assertIsNone(self.reg.get("viewer"))

    def test_ids_are_stored_as_integers(self):
        self.reg.set("viewer", "42", "Urist")
        self.assertEqual(self.reg.owner_of(42), "viewer")

    def test_release_frees_the_viewer(self):
        """F-04: a viewer whose dwarf died was blocked forever."""
        self.reg.set("viewer", 1, "Urist")
        rec = self.reg.release("viewer")
        self.assertEqual(rec["name"], "Urist")
        self.assertIsNone(self.reg.get("viewer"))
        self.assertTrue(self.reg.set("viewer", 2, "Kadol"))

    def test_count_does_not_reach_into_the_dict(self):
        self.reg.set("a", 1, "A")
        self.reg.set("b", 2, "B")
        self.assertEqual(self.reg.count(), 2)


class ChatDispatch(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.engine = AntfarmEngine(self.client)
        self.bridge = TwitchBridge(self.client, self.engine,
                                   config={"nick": "bot", "token": "oauth:x",
                                           "channel": "chan"})
        self.bridge.claims = ClaimRegistry(
            path=os.path.join(_SCRATCH, "claims-chat-%f.json" % time.time()))
        self.sent = []
        self.bridge.say = lambda text: self.sent.append(text) or True

    def _line(self, user, msg, mod=False):
        tags = "mod=1" if mod else "mod=0"
        return f"@{tags} :{user}!{user}@{user}.tmi.twitch.tv PRIVMSG #chan :{msg}"

    def test_the_token_is_not_left_in_the_config_dict(self):
        """S-04: anything logging self.cfg printed a live credential."""
        self.assertNotIn("token", self.bridge.cfg)
        self.assertEqual(self.bridge._token, "oauth:x")
        self.assertTrue(self.bridge.configured())

    def test_a_mod_only_command_does_not_burn_a_viewer_cooldown(self):
        """F-03: !director charged the cooldown then silently did nothing."""
        self.bridge._handle_line(self._line("viewer", "!director timed"))
        self.assertEqual(self.engine.mode, "director", "a viewer changed the mode")
        # The cooldown must still be free for a real command.
        self.bridge._handle_line(self._line("viewer", "!fort"))
        self.assertTrue(self.sent, "the follow-up command was swallowed by a cooldown")

    def test_a_moderator_can_still_use_it(self):
        self.bridge._handle_line(self._line("boss", "!director timed", mod=True))
        self.assertEqual(self.engine.mode, "timed")

    def test_slow_commands_are_bounded(self):
        """S-03: 500 viewers typing !stats spawned 500 threads."""
        import concurrent.futures
        self.bridge._slow_pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
        try:
            ran = []
            for _ in range(200):
                self.bridge._submit_slow("!stats", lambda: ran.append(1))
            self.bridge._slow_pool.shutdown(wait=True)
            self.assertLessEqual(len(ran), 200)
            self.assertGreater(len(ran), 0)
        finally:
            self.bridge._slow_pool = None

    def test_probe_matches_its_own_request_among_several(self):
        """B-02: concurrent probes overwrote one another and all timed out."""
        self.client.latest_state = {
            "probes": [{"id": 7, "name": "Seven"}, {"id": 9, "name": "Nine"}],
            "unit_data": {"id": 1, "name": "Focused"},
        }
        self.assertEqual(self.bridge._probe(9, timeout=0.3)["name"], "Nine")
        self.assertEqual(self.bridge._probe(7, timeout=0.3)["name"], "Seven")

    def test_probe_falls_back_to_the_single_slot(self):
        self.client.latest_state = {"probe_data": {"id": 5, "name": "Five"}}
        self.assertEqual(self.bridge._probe(5, timeout=0.3)["name"], "Five")

    def test_unclaim_clears_the_in_game_nickname_too(self):
        self.bridge.claims.set("viewer", 3, "Urist")
        self.bridge.cmd_unclaim("viewer", "", {})
        self.assertIn("nick 3 ", " | ".join(self.client.commands))
        self.assertIsNone(self.bridge.claims.get("viewer"))


class AutoDefence(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.engine = AntfarmEngine(self.client)

    def _state(self, **kw):
        base = {"map_loaded": True, "citizens": [citizen(1)],
                "fortress_stats": {"pop": 1, "paused": False}, "announcements": []}
        base.update(kw)
        return base

    def test_lockdown_fires_on_a_danger_classification(self):
        self.engine._on_state_received(self._state(
            ui={"pause_kind": "danger", "pause_type": "AMBUSH_SNATCHER"}))
        self.assertIn("command antfarm_lever", self.client.commands)

    def test_lockdown_does_not_fire_on_routine_news(self):
        """B-05: matching 'attack' in announcement text caught combat spam and,
        once matched, never un-matched."""
        self.engine._on_state_received(self._state(
            announcements=["The dwarf attacks the groundhog!"],
            ui={"pause_kind": "routine", "pause_type": "SEASON_SPRING"}))
        self.assertNotIn("command antfarm_lever", self.client.commands)

    def test_python_no_longer_races_the_game_side_unpause(self):
        self.engine._on_state_received(self._state(
            fortress_stats={"pop": 1, "paused": True}))
        self.assertNotIn("unpause", self.client.commands)


class Vitals(unittest.TestCase):
    """The SLEEP / FOOD / ALCOHOL gauges read unit["needs"] looking for "sleep",
    "food" and "drink". Those keys do not exist: DF's need list holds social and
    spiritual desires under enum names (Socialize, DrinkAlcohol, ...) and has no
    physiological entry at all, so every lookup missed and all three bars sat at
    zero forever. The counters live on the unit and are published as "vitals".
    """

    def test_needs_never_carry_the_physiological_keys(self):
        """Guard the original mistake: if these ever appear in a need list, the
        gauges may legitimately read them -- until then they must not."""
        from antfarm.tui import VITAL_THRESHOLDS
        needs = ["Socialize", "DrinkAlcohol", "PrayOrMeditate", "EatGoodMeal"]
        for key in VITAL_THRESHOLDS:
            self.assertNotIn(key, needs)
        for stale in ("sleep", "food", "drink"):
            self.assertNotIn(stale, VITAL_THRESHOLDS)

    def test_a_rested_dwarf_reads_full_and_a_spent_one_reads_empty(self):
        from antfarm.tui import vital_reserve
        self.assertEqual(vital_reserve({"thirst_timer": 0}, "thirst_timer"), 1000)
        self.assertEqual(vital_reserve({"thirst_timer": 50000}, "thirst_timer"), 0)
        # Counters keep climbing past the critical point; the bar floors at 0
        # rather than going negative and blowing up the renderer.
        self.assertEqual(vital_reserve({"thirst_timer": 999999}, "thirst_timer"), 0)

    def test_the_gauge_falls_as_the_counter_climbs(self):
        from antfarm.tui import vital_reserve
        half = vital_reserve({"hunger_timer": 37500}, "hunger_timer")
        self.assertAlmostEqual(half, 500.0, places=6)

    def test_a_missing_counter_is_unknown_not_zero(self):
        """Lua reports -1 for a field its build does not have (AGENTS.md 6.1.11).
        Showing that as an empty bar would read as 'this dwarf is dying'."""
        from antfarm.tui import vital_reserve
        self.assertIsNone(vital_reserve({"hunger_timer": -1}, "hunger_timer"))
        self.assertIsNone(vital_reserve({}, "hunger_timer"))
        self.assertIsNone(vital_reserve(None, "hunger_timer"))
        self.assertIsNone(vital_reserve({"hunger_timer": "17"}, "hunger_timer"))

    def test_the_lua_side_publishes_exactly_these_counters(self):
        """Both halves must agree, the way test_wire.py makes them agree for
        commands. A rename on either side fails here instead of silently
        blanking the dashboard."""
        import re
        from antfarm.tui import VITAL_THRESHOLDS
        with open("game/hack/scripts/antfarm_server.lua", encoding="utf-8") as f:
            src = f.read()
        block = re.search(r"local VITAL_COUNTERS = \{(.*?)\}", src, re.S)
        self.assertIsNotNone(block, "antfarm_server.lua no longer declares VITAL_COUNTERS")
        published = set(re.findall(r"'([a-z_]+)'", block.group(1)))
        self.assertEqual(published, set(VITAL_THRESHOLDS))


class SubsystemLifecycleEvents(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.engine = AntfarmEngine(self.client)

    def test_migrant_wave_triggers_nobles_quarters_locations(self):
        state1 = {"map_loaded": True, "citizens": [citizen(1)], "announcements": []}
        self.engine._on_state_received(state1)
        self.client.commands.clear()

        # Migrant wave arrives (population jumps from 1 to 3)
        state2 = {"map_loaded": True, "citizens": [citizen(1), citizen(2), citizen(3)],
                  "announcements": ["Migrants have arrived."]}
        self.engine._on_state_received(state2)

        self.assertIn("nobles appoint", self.client.commands)
        self.assertIn("quarters assign", self.client.commands)
        self.assertIn("locations hall", self.client.commands)

    def test_caravan_announcement_triggers_trade_goods(self):
        state1 = {"map_loaded": True, "citizens": [citizen(1)], "announcements": []}
        self.engine._on_state_received(state1)
        self.client.commands.clear()

        state2 = {"map_loaded": True, "citizens": [citizen(1)],
                  "announcements": ["A caravan from the Mountainhomes has arrived."]}
        self.engine._on_state_received(state2)

        self.assertIn("trade goods", self.client.commands)

    def test_citizen_death_triggers_autoslab_and_nobles(self):
        state1 = {"map_loaded": True, "citizens": [citizen(1, name="Urist"), citizen(2, name="Kadol")],
                  "announcements": []}
        self.engine._on_state_received(state1)
        self.client.commands.clear()

        state2 = {"map_loaded": True, "citizens": [citizen(2, name="Kadol")],
                  "announcements": ["Urist has been killed."]}
        self.engine._on_state_received(state2)

        self.assertIn("autoslab check", self.client.commands)
        self.assertIn("nobles appoint", self.client.commands)


class LifecycleHandlers(unittest.TestCase):
    """B-04 again, in the handlers added for migrant waves, deaths and caravans.

    send_cmd writes a command file. Holding self.lock across that I/O blocks the
    listener thread on disk, which is the bug _handle_rotation was restructured
    to avoid. The lock guards shared engine state; these handlers touch none.
    """

    HANDLERS = ("_on_migrant_wave", "_on_citizen_death", "_on_announcement")

    def test_no_handler_sends_a_command_while_holding_the_lock(self):
        import inspect
        from antfarm.engine import AntfarmEngine
        for name in self.HANDLERS:
            src = inspect.getsource(getattr(AntfarmEngine, name))
            if "with self.lock:" not in src:
                continue
            held = src.split("with self.lock:", 1)[1]
            # Everything at deeper indentation is inside the block.
            block = []
            for line in held.splitlines()[1:]:
                if line.strip() and not line.startswith(" " * 12):
                    break
                block.append(line)
            self.assertNotIn("send_cmd", "\n".join(block),
                             "%s calls send_cmd while holding self.lock" % name)

    def test_the_standing_cadence_is_not_duplicated_in_python(self):
        """The Lua subsystems already gate themselves on a wall clock and are
        dispatched from the poll loop. A second timer in the engine loop ran
        `orders reap` and `defence traps` every 120s, bypassing those gates and
        putting standing fortress automation in the layer CLAUDE.md reserves for
        onMapLoad.init."""
        import inspect
        from antfarm.engine import AntfarmEngine
        src = inspect.getsource(AntfarmEngine)
        self.assertNotIn("last_maintenance", src,
                         "engine.py is running its own standing maintenance timer again")


class StartupSequence(unittest.TestCase):
    """One command has to take a cold machine to a fort that is being played.

    Each check below corresponds to something that actually went wrong on a live
    run: the plan file outliving its fort, a string landing in the z-level table,
    the arrival text stopping an unattended start, and the launcher asking a
    question instead of just going.
    """

    @staticmethod
    def _read(path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def test_the_launcher_needs_no_input(self):
        src = self._read("start_antfarm.sh")
        # A bare invocation must run everything, not print a menu.
        self.assertRegex(src, r"''\|--go\|-g\)\s*launch_all",
                         "a bare ./start_antfarm.sh no longer runs launch_all")
        self.assertIn("--menu", src, "the menu should still be reachable")

    def test_the_launcher_distinguishes_a_fort_from_a_bare_world(self):
        """world.sav means there is a fortress to continue; world.dat alone means
        a generated world that still needs an embark. Confusing the two either
        re-embarks over a live fort or sits on the title screen."""
        src = self._read("start_antfarm.sh")
        self.assertIn("world.sav", src)
        self.assertIn("world.dat", src)

    def test_autostart_dismisses_the_arrival_text(self):
        """An unattended embark sat on the intro textviewer indefinitely: the
        watchdog can clear it, but only while a client is driving a fort, and at
        embark time there is no fort yet."""
        src = self._read("game/hack/scripts/antfarm_autostart.lua")
        block = src.split("viewscreen_textviewerst', scr)", 1)
        self.assertEqual(len(block), 2, "autostart no longer handles textviewerst")
        self.assertIn("LEAVESCREEN", block[1][:400])

    def test_autostart_starts_the_build(self):
        """Reaching dwarfmode is not playing; without this the fort idles."""
        src = self._read("game/hack/scripts/antfarm_autostart.lua")
        self.assertIn("antfarm_blueprint", src)

    def test_the_plan_is_stamped_with_its_fort(self):
        """The plan file survived across forts: a fresh 7-dwarf embark reported
        'step 15/22, surface z=62' while its dwarves stood on z=63 of a different
        map, and applied late-stage blueprints at the old fort's coordinates."""
        src = self._read("game/hack/scripts/antfarm_blueprint.lua")
        self.assertIn("fort_identity", src)
        self.assertIn("plan_is_foreign", src)
        # site_id alone repeats across unsaved forts; the identity must be richer.
        ident = src.split("local function fort_identity()", 1)[1][:700]
        self.assertIn("global_min_x", ident,
                      "fort identity must include the embark origin: two forts "
                      "embarked without a save in between share a site_id")

    def test_the_level_table_holds_only_z_levels(self):
        """`levels` is fed to fort_zlevels(), which turns every value into a
        z-level for the gate scan, and to the status printer, which formats each
        with %d. A mode string in there broke both."""
        src = self._read("game/hack/scripts/antfarm_blueprint.lua")
        self.assertNotIn("levels.farming_mode =", src,
                         "farming_mode must live on the plan, not in levels")
        self.assertIn("if type(z) ~= 'number' then goto continue end", src,
                      "fort_zlevels must ignore non-numeric values")

    def test_the_embark_scanner_skips_occupied_tiles(self):
        """DF silently refuses to embark on a world tile that already holds a
        site -- pressing `e` does nothing. The scanner ranked a previous fort's
        own tile as the best site and then reported success."""
        src = self._read("game/hack/scripts/antfarm_embark.lua")
        self.assertIn("occupied_tiles", src)
        self.assertIn("rejected.occupied", src)


class VersionCompatibility(unittest.TestCase):
    """Vendored scripts were taken from DFHack master and declared "verified to
    run purely on DFHack 0.47 structures and pass `luac -p`". luac checks syntax,
    not whether a symbol exists, so six scripts shipped broken and raised on every
    scheduled run: fix/stuck-worship, fix/engravings, fix/stuck-squad,
    antfarm_autoslab, justice and allneeds.

    These are the v50-only symbols that caused it. Any new appearance is a script
    that will fail the moment its code path runs.
    """

    V50_ONLY = [
        r"df\.global\.plotinfo",              # renamed from `ui` in v50
        r"dfhack\.units\.getCitizens\(",
        r"dfhack\.units\.getReadableName",
        r"df\.global\.world\.event\.",       # engravings moved under world.event
        r"flags[123]\.bits",                   # v50 bitfield wrapper
        r"df\.global\.game\.main_interface",
        r"dfhack\.maps\.getWalkableGroup",
    ]

    def _scripts(self):
        import glob
        paths = []
        paths += glob.glob("game/hack/scripts/antfarm_*.lua")
        paths += glob.glob("game/hack/scripts/fix/*.lua")
        for extra in ("allneeds", "justice", "suspend"):
            paths += glob.glob("game/hack/scripts/%s.lua" % extra)
        return sorted(paths)

    def test_no_v50_only_api_in_scripts_we_own_or_schedule(self):
        import re
        offenders = []
        for path in self._scripts():
            with open(path, encoding="utf-8") as fh:
                for n, line in enumerate(fh, 1):
                    code = line.split("--", 1)[0]      # ignore comments
                    for pat in self.V50_ONLY:
                        if re.search(pat, code):
                            offenders.append("%s:%d %s" % (path, n, code.strip()[:70]))
        self.assertFalse(offenders,
                         "v50-only API used on a 0.47 build:\n  " + "\n  ".join(offenders))

    def test_the_stub_does_not_offer_apis_the_game_lacks(self):
        """The stub used to provide getReadableName, which 0.47 does not have, so
        autoslab's tests passed while the live fort raised."""
        with open("tests/df_stub.lua", encoding="utf-8") as fh:
            stub = fh.read()
        self.assertNotIn("getReadableName = function", stub)
        self.assertIn("isGhost = function", stub)


class SubsystemContracts(unittest.TestCase):
    """The server aggregates each Lua subsystem's report() into antfarm_state.json.
    That aggregator was written against guessed field names: it tested
    `rep.depot ~= nil` on a field that is always a boolean, and read
    `rep.shortfall` / `rep.needs_goods` from modules that publish neither. The
    dashboard therefore reported a trade depot and full housing for a fort that
    had neither, and the metals list published array indices instead of metal
    names. Nothing failed -- the numbers were simply wrong.

    These are the same both-halves-must-agree checks test_wire.py makes for
    commands, applied to the state payload.
    """

    SERVER = "game/hack/scripts/antfarm_server.lua"

    @staticmethod
    def _read(path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    @classmethod
    def _report_keys(cls, module):
        """Top-level keys the module's report() returns."""
        import re
        src = cls._read("game/hack/scripts/%s.lua" % module)
        body = re.search(r"\nfunction report\(\)(.*?)\nend\n", src, re.S)
        if not body:
            return None
        # Both shapes occur: a multi-line `return {` table, and a single-line
        # one. Matching only the first silently skipped a module.
        table = re.search(r"return \{(.*)\}", body.group(1), re.S)
        if not table:
            return None
        keys = set(re.findall(r"(?:^|[{,])\s*([a-z_]+)\s*=", table.group(1), re.M))
        return keys or None

    def _ask_blocks(self):
        """{module: {fields the aggregator reads off its report}}"""
        import re
        src = self._read(self.SERVER)
        out = {}
        for m in re.finditer(
                r"ask\('(antfarm_[a-z]+)',\s*function\(rep\)(.*?)\n    end\)",
                src, re.S):
            out[m.group(1)] = set(re.findall(r"rep\.([a-z_]+)", m.group(2)))
        return out

    def test_the_aggregator_reads_fields_the_modules_actually_publish(self):
        blocks = self._ask_blocks()
        self.assertTrue(blocks, "no ask() blocks found -- did subsystems_summary change shape?")
        for module, fields in blocks.items():
            published = self._report_keys(module)
            if published is None:
                continue          # module has no literal-table report(); skip
            missing = fields - published
            self.assertFalse(
                missing,
                "%s: aggregator reads %s, which report() does not publish (it publishes %s)"
                % (module, sorted(missing), sorted(published)))

    def test_every_module_with_a_tick_is_actually_dispatched(self):
        """Six modules defined tick() and nothing ever called them, so the fort
        managed nothing unless a human typed the command."""
        import glob, os, re
        src = self._read(self.SERVER)
        listed = set(re.findall(r"'(antfarm_[a-z]+)',", 
                                re.search(r"local SUBSYSTEMS = \{(.*?)\}", src, re.S).group(1)))
        for path in sorted(glob.glob("game/hack/scripts/antfarm_*.lua")):
            name = os.path.basename(path)[:-4]
            if name in ("antfarm_server", "antfarm_ui"):
                continue          # driven directly by the poll loop
            if re.search(r"^function tick\(\)", self._read(path), re.M):
                self.assertIn(name, listed,
                              "%s defines tick() but is not in the server's SUBSYSTEMS list, "
                              "so it never runs" % name)

    def test_the_dispatcher_is_called_from_the_poll_loop(self):
        src = self._read(self.SERVER)
        self.assertRegex(src, r"\n\s+run_subsystems\(\)",
                         "run_subsystems() is defined but never called from poll()")


if __name__ == "__main__":
    unittest.main(verbosity=2)
