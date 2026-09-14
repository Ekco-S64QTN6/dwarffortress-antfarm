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


if __name__ == "__main__":
    unittest.main(verbosity=2)
