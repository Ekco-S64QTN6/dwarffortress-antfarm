import time
import threading
import logging
import os
from antfarm.client import DFClient
from antfarm.event_engine import EventBus, EventEngine, DFEvent
from antfarm.knowledge_graph import SimulationKnowledgeGraph
from antfarm.sdk import PluginManager

class AntfarmEngine:
    def __init__(self, client: DFClient, interval=15):
        self.client = client
        self.rotation_interval = interval
        self.mode = "director"  # "director", "timed", "event", "idle"
        self.last_rotation_time = 0
        self.current_dwarf_index = 0
        
        self.running = False
        self.thread = None
        self.lock = threading.RLock()
        
        # Connect Event Bus & Event Engine (DF Companion 2.0 Core)
        self.event_bus = EventBus()
        self.event_engine = EventEngine(self.event_bus)
        
        # Subscribe to all events on the Event Bus
        self.event_bus.subscribe("*", self._on_event_received)

        # Live relationship graph, kept separate from the Legends archive: this
        # one records what happens during the stream, not recorded history.
        self.knowledge_graph = SimulationKnowledgeGraph()

        # Third-party plugins drop into app/plugins/ and get the bus and graph.
        self.plugin_manager = PluginManager(self.event_bus, self.knowledge_graph)
        self._load_plugins()
        
        # Dictionary of active interest events: dwarf_id -> list of DFEvent
        self.interest_events = {}
        
        # Connect callbacks
        self.client.add_citizens_callback(self._on_citizens_received)
        self.client.add_state_callback(self._on_state_received)
        
        self.citizens = []
        self.active_unit_id = None
        self.last_announcement = None
        self.stress_history = {}
        self.bootstrapped = False
        self.last_lockdown = 0.0

        # Whether to site and build a Dreamfort automatically.
        #
        # Default is "auto": build it on a fort that has clearly never been
        # touched, leave an established one alone. Defaulting to off looked
        # cautious and was simply wrong -- a fresh embark then sat with nothing
        # designated, every dwarf idle beside the wagon, which is exactly the
        # failure this project exists to prevent. Defaulting to on unconditionally
        # is also wrong: on a hand-built fortress it would designate several
        # thousand tiles somewhere the player did not choose.
        #
        # ANTFARM_AUTOBUILD=1 forces it on, =0 forces it off.
        env = os.environ.get("ANTFARM_AUTOBUILD", "").strip().lower()
        if env in ("1", "true", "yes", "on"):
            self.autobuild = True
        elif env in ("0", "false", "no", "off"):
            self.autobuild = False
        else:
            self.autobuild = None   # decide from the fort itself

        # How far ahead a rival dwarf must score before the camera moves.
        # docs/automation-research.md derives 150; the value had drifted to 40,
        # which let a single decayed CitizenStartedJob (weight 100, half-life
        # 30s) yank the camera off whatever was actually happening.
        self.hysteresis_threshold = float(os.environ.get("ANTFARM_HYSTERESIS", "150"))

        # Viewer camera override: while this is in the future the Director AI
        # keeps scoring but stops steering, so a chat !focus is not overruled a
        # second later by whichever dwarf happens to be interesting.
        self.override_until = 0.0
        self.override_unit_id = None
        self.override_owner = None
        
    def _load_plugins(self):
        plugin_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "plugins")
        if os.path.isdir(plugin_dir):
            self.plugin_manager.load_plugins_from_directory(plugin_dir)

    def _record_citizen_nodes(self, citizens):
        """Keep the knowledge graph's dwarf nodes in step with the roster."""
        for d in citizens:
            d_id = d.get("id")
            if d_id is None:
                continue
            node = self.knowledge_graph.get_node(d_id)
            if node is None:
                node = self.knowledge_graph.add_node(d_id, "dwarf", d.get("name", "Unknown"))
            else:
                node.name = d.get("name", node.name)
            node.properties.update({
                "profession": d.get("profession"),
                "job": d.get("current_job"),
                "stress": d.get("stress"),
                "nick": d.get("nick"),
            })

    def start(self):
        with self.lock:
            if self.running:
                return
            self.running = True
            self.thread = threading.Thread(target=self._run_loop, daemon=True)
            self.thread.start()
            logging.info("Antfarm Automation Engine started.")

        # The bootstrap payload is ~30 DFHack commands paced 250ms apart. Run it
        # on its own thread: doing it inline stalls the caller for eight seconds
        # before the TUI ever paints, and the commands are pointless until a
        # fortress is actually loaded anyway.
        threading.Thread(target=self._bootstrap_when_ready, daemon=True).start()

    def stop(self):
        with self.lock:
            self.running = False
            # Reset so a restarted engine bootstraps its next session. Left
            # True, a stop/start cycle silently skipped the bootstrap forever.
            self.bootstrapped = False
        # Hand the camera back rather than waiting out the 5s Lua heartbeat.
        try:
            self.client.unfocus()
        except Exception:
            pass

    def _bootstrap_when_ready(self):
        # Wait for a live fortress before firing automation commands, so a TUI
        # started ahead of the game does not spray them into the void.
        deadline = time.time() + 600
        while self.running and time.time() < deadline:
            state = self.client.latest_state
            if state and state.get("map_loaded") and state.get("fortress_stats", {}).get("pop", 0) > 0:
                break
            time.sleep(1.0)
        # Check-and-set under the lock: a stop/start cycle can leave two
        # bootstrap threads in flight, and the init file warns that firing
        # `prioritize` twice double-registers it.
        with self.lock:
            if not self.running or self.bootstrapped:
                return
            self.bootstrapped = True
        self.execute_initial_payloads()
            
    def execute_initial_payloads(self):
        """Bring up the automation that has to be driven from here.

        Standing fortress automation (autofarm, workflow, autobutcher, seedwatch,
        ban-cooking, the recurring housekeeping jobs...) lives in
        game/dfhack-config/init/onMapLoad.init, where DFHack applies it
        on every load and the user can edit it without touching code. Repeating
        it here would double-register the `repeat` jobs and, worse, re-enable
        plugins the init file deliberately leaves off.

        What is left is the part that depends on this being a *streamed* fort.
        """
        payloads = [
            # Keep the fort visibly busy: workshops and constructions first.
            "prioritize -aq defaults",
        ]
        if self.autobuild is None:
            self.autobuild = self._fort_looks_untouched()
        if self.autobuild:
            # Survey the embark, anchor a Dreamfort near the dwarves and turn
            # auto mode on. Idempotent: on a fort that is already anchored it
            # only makes sure the build is running.
            payloads.append("antfarm_blueprint autostart")
        else:
            # Report progress if the operator anchored one by hand; no-op
            # otherwise.
            payloads.append("antfarm_blueprint status")
        logging.info("Running Antfarm session bootstrap...")
        for p in payloads:
            self.client.execute_dfhack(p)
            time.sleep(0.25)

    def _fort_looks_untouched(self):
        """Is this a fresh embark nobody has built on yet?

        The signal is the build plan the game side reports: `anchored` is false
        until someone runs `antfarm_blueprint here` or `autostart`, and step 1
        means nothing has been applied. Combined with a small population, that
        is an embark that has just landed.

        Deliberately conservative: anything unclear reads as "leave it alone".
        """
        state = self.client.latest_state or {}
        build = state.get("build")
        if build is None:
            # No plan data at all -- the blueprint script did not answer, so we
            # do not know what this fort is. Do not designate anything.
            logging.info("Autobuild: no build plan reported; leaving the fort alone.")
            return False
        if build.get("anchored"):
            logging.info("Autobuild: this fort is already anchored; not re-siting it.")
            return False
        pop = (state.get("fortress_stats") or {}).get("pop", 0)
        if pop > 20:
            logging.info("Autobuild: %d citizens already here; this is not a fresh "
                         "embark, leaving it alone.", pop)
            return False
        logging.info("Autobuild: fresh embark (%d citizens, no anchor) -- siting a "
                     "Dreamfort. Set ANTFARM_AUTOBUILD=0 to stop this.", pop)
        return True

    def _run_loop(self):
        while self.running:
            try:
                # The roster arrives with every state frame; nothing to request.
                self._handle_rotation()
                
                # Send heartbeat command and mode to keep overlay updated in Lua
                with self.lock:
                    self.client.send_cmd(f"mode {self.mode}")
                    self.client.send_cmd("ping")
                
                time.sleep(1.0)
            except Exception as e:
                logging.error(f"Error in Antfarm loop: {e}")
                time.sleep(2.0)
                
    def _on_citizens_received(self, list_data):
        with self.lock:
            self.citizens = list_data
            self._prune_departed(list_data)
        try:
            self._record_citizen_nodes(list_data)
        except Exception as e:
            logging.error(f"Knowledge graph update failed: {e}")

    def _prune_departed(self, citizens):
        """Forget dwarves who are no longer on the roster.

        stress_history and interest_events are keyed by dwarf id and nothing
        ever removed an entry, so a long stream accumulated one per dead or
        departed dwarf -- and a death event (weight 2000, half-life 600s) kept
        its interest entry alive for over an hour after the dwarf was gone.
        The knowledge graph had the same problem: ghost nodes went on counting
        towards the centrality of everyone they were related to.

        An empty roster means "no information" (the player quit to the menu),
        not "everyone left", so it is never treated as a mass departure.
        """
        if not citizens:
            return
        live = {d.get("id") for d in citizens if d.get("id") is not None}
        for table in (self.stress_history, self.interest_events):
            for d_id in [k for k in table if k != "global" and k not in live]:
                table.pop(d_id, None)
        try:
            self.knowledge_graph.prune_to(live)
        except Exception as e:
            logging.error(f"Knowledge graph prune failed: {e}")
            
    def _on_state_received(self, state_data):
        # Pass state changes through the Event Engine to generate events dynamically
        self.event_engine.process_state(state_data)

        for plugin in list(self.plugin_manager.plugins.values()):
            if plugin.enabled:
                try:
                    plugin.on_tick(state_data)
                except Exception as e:
                    logging.error(f"Plugin {plugin.name} on_tick failed: {e}")
        
        unit_data = state_data.get("unit_data")
        if unit_data:
            # Written under the lock like every other shared field: this runs on
            # the DFClient listener thread while _handle_rotation reads it on
            # the engine thread.
            with self.lock:
                self.active_unit_id = unit_data.get("id")

        # Auto-defence. The *classification* now comes from the game side:
        # antfarm_ui identifies the announcement that paused the fort by its
        # df.announcement_type, which is what DF itself keys on, rather than by
        # searching the text for words like "attack" -- combat spam during a
        # siege matches that too, and once matched the old code never
        # un-matched, which suppressed auto-unpause for the rest of the session.
        ui = state_data.get("ui") or {}
        if ui.get("pause_kind") == "danger":
            if time.time() - self.last_lockdown > 30:
                self.last_lockdown = time.time()
                logging.warning(
                    "Auto-Defense: lockdown on %s -- %s",
                    ui.get("pause_type", "threat"), ui.get("pause_text", ""))
                self.client.execute_dfhack("antfarm_lever")

        announcements = state_data.get("announcements", [])
        if announcements and announcements[0] != self.last_announcement:
            self.last_announcement = announcements[0]

        # Auto-unpause is no longer driven from here. antfarm_ui owns it: it can
        # clear the blocking popup first (the game re-pauses instantly while one
        # is queued, so poking pause_state from Python simply did not work),
        # press the key a player would press, and put the camera back afterwards.
            
    def _on_event_received(self, event):
        # Accumulate interest events
        d_id = event.payload.get("id")
        with self.lock:
            if d_id is not None:
                if d_id not in self.interest_events:
                    self.interest_events[d_id] = []
                self.interest_events[d_id].append(event)
                logging.info(f"Event: Added interest boost to Dwarf {event.payload.get('name')} from event '{event.name}' (+{event.weight} weight)")
            else:
                if "global" not in self.interest_events:
                    self.interest_events["global"] = []
                self.interest_events["global"].append(event)
                logging.info(f"Event: Added global interest boost from event '{event.name}' (+{event.weight} weight)")
            
    def calculate_interest_score(self, d_id, base_stress=0, profession="", density=0,
                                relations=0, sample=False):
        """Score a dwarf's watchability.

        `sample` records the stress reading used for the volatility term. Only
        the camera-rotation path passes it: the TUI re-scores every citizen up
        to five times a second just to draw a number, and if that also moved the
        baseline the volatility term would be computed over whatever window the
        UI happened to sample. The same fortress would then steer the camera
        differently depending on whether the dashboard was open.
        """
        with self.lock:
            now = time.time()
            score = 0
            
            # 1. Base weights from dwarf properties
            if base_stress > 0:
                score += base_stress * 0.01
                
            nobles = ["Expedition Leader", "Mayor", "Baron", "Baroness", "Duke", "Duchess", "King", "Queen", "Sheriff", "Hammerer"]
            if any(n in profession for n in nobles):
                score += 150
                
            if "Legendary" in profession:
                score += 100
                
            # Spatial Entity Density (SD)
            score += density * 5.0
            
            # Knowledge Graph Centrality (KGC)
            score += relations * 10.0
            
            # Stress Volatility Delta (SVD)
            if d_id in self.stress_history:
                prev_stress, prev_time = self.stress_history[d_id]
                dt = now - prev_time
                if dt > 0.01:
                    volatility = abs(base_stress - prev_stress) / dt
                    score += volatility * 100.0
            if sample:
                self.stress_history[d_id] = (base_stress, now)
                
            # 2. Add decaying events
            if d_id in self.interest_events:
                active_events = []
                for event in self.interest_events[d_id]:
                    current_val = event.get_current_interest(now)
                    if current_val > 0.1:
                        score += current_val
                        active_events.append(event)
                self.interest_events[d_id] = active_events
                
            # 3. Add global decaying events (announcements)
            if "global" in self.interest_events:
                active_globals = []
                for event in self.interest_events["global"]:
                    current_val = event.get_current_interest(now)
                    if current_val > 0.1:
                        score += current_val * 0.2  # global events contribute 20% of their weight to all dwarfs
                        active_globals.append(event)
                self.interest_events["global"] = active_globals
                
            return score
        
    def viewer_focus(self, unit_id, owner=None, duration=45.0):
        """Pin the camera on a dwarf on behalf of a chat viewer."""
        with self.lock:
            self.override_unit_id = unit_id
            self.override_owner = owner
            self.override_until = time.time() + duration
            self.active_unit_id = unit_id
            self.last_rotation_time = time.time()
        self.client.focus_unit(unit_id)
        logging.info(f"Viewer override: {owner or 'chat'} locked camera onto unit {unit_id} for {duration:.0f}s")
        return True

    def clear_override(self):
        with self.lock:
            self.override_until = 0.0
            self.override_unit_id = None
            self.override_owner = None

    def override_active(self):
        with self.lock:
            return time.time() < self.override_until

    def score_citizen(self, d, sample=False):
        """The interest score for one citizen record.

        Every caller goes through here. There used to be three call sites with
        three different argument sets -- the TUI header omitted density and
        relations entirely -- so the INTEREST number on screen was not the
        number the Director was steering by.
        """
        d_id = d.get("id")
        return self.calculate_interest_score(
            d_id=d_id,
            base_stress=d.get("stress", 0) or 0,
            profession=d.get("profession", "") or "",
            density=d.get("density", 0) or 0,
            relations=len(self.knowledge_graph.get_neighbors(d_id)),
            sample=sample,
        )

    def ranked_citizens(self):
        """Citizens with their current interest score, most interesting first."""
        with self.lock:
            scored = [(self.score_citizen(d), d) for d in self.citizens]
            scored.sort(key=lambda x: x[0], reverse=True)
            return scored

    def find_citizen(self, query):
        """Resolve a chat-supplied name to a citizen record.

        Matches nickname first (that is what a viewer who claimed a dwarf will
        type), then full name, on exact match before substring.
        """
        if not query:
            return None
        q = query.strip().lower()
        with self.lock:
            citizens = list(self.citizens)

        for field in ("nick", "name"):
            for d in citizens:
                if (d.get(field) or "").lower() == q:
                    return d
        for field in ("nick", "name"):
            for d in citizens:
                if q and q in (d.get(field) or "").lower():
                    return d
        return None

    def next_citizen(self, owner=None):
        """Advance the camera to the next dwarf down the interest ranking."""
        scored = self.ranked_citizens()
        if not scored:
            return None
        pool = [d for _, d in scored[:max(1, min(10, len(scored)))]]
        current = self.active_unit_id
        idx = 0
        for i, d in enumerate(pool):
            if d.get("id") == current:
                idx = (i + 1) % len(pool)
                break
        target = pool[idx]
        self.viewer_focus(target.get("id"), owner=owner)
        return target

    def unclaimed_citizens(self):
        with self.lock:
            return [d for d in self.citizens if not d.get("claimed") and not (d.get("nick") or "").strip()]

    def _handle_rotation(self):
        """Decide where the camera should be, then move it outside the lock.

        Nothing in here calls the client while holding self.lock. focus_unit()
        writes a file, and the DFClient listener thread needs the same lock to
        deliver state at 5Hz -- holding it across a filesystem write stalled
        event delivery, and events are what the Director steers by.
        """
        target = None
        with self.lock:
            if not self.citizens:
                return

            now = time.time()

            # A viewer holds the camera; keep the lock alive and score in the
            # background, but do not steer.
            if now < self.override_until:
                target = self.override_unit_id
            else:
                target = self._choose_target(now)

        if target is not None:
            self.client.focus_unit(target)

    def _choose_target(self, now):
        """Pick the unit the camera should be on. Caller holds self.lock.

        Returns a unit id to move to, or None to stay put.
        """
        scored_citizens = [(self.score_citizen(d, sample=True), d) for d in self.citizens]
        scored_citizens.sort(key=lambda x: x[0], reverse=True)

        # Find currently followed citizen's score if present
        current_score = 0
        current_citizen = None
        if self.active_unit_id:
            for score, d in scored_citizens:
                if d.get("id") == self.active_unit_id:
                    current_score = score
                    current_citizen = d
                    break

        # 1. Director AI mode (threshold-based hysteresis lock with exponential decay)
        if self.mode == "director":
            # Enforce a minimum follow duration (cooldown) to prevent rapid ping-ponging
            min_follow_duration = 10.0
            if self.active_unit_id and current_citizen and (now - self.last_rotation_time < min_follow_duration):
                return None

            highest_score, highest_dwarf = scored_citizens[0]

            # Apply a decay penalty to the currently followed citizen to encourage rotation if followed a long time
            decayed_current_score = current_score
            if self.active_unit_id and current_citizen:
                time_focused = now - self.last_rotation_time
                if time_focused > 10.0:
                    decayed_current_score -= (time_focused - 10.0) * 2.0

            if (not self.active_unit_id or
                    not current_citizen or
                    highest_score > decayed_current_score + self.hysteresis_threshold):

                if highest_dwarf.get("id") != self.active_unit_id:
                    logging.info(f"Director AI: Locking focus onto {highest_dwarf.get('name')} "
                                 f"(Interest Score: {highest_score:.1f}, Job: {highest_dwarf.get('current_job')})")
                    self.last_rotation_time = now
                    self.active_unit_id = highest_dwarf.get("id")
                    return self.active_unit_id
            return None

        # 2. Timed rotation mode (cycles through the top 5 most interesting dwarfs)
        if self.mode == "timed":
            if now - self.last_rotation_time >= self.rotation_interval:
                top_pool = scored_citizens[:min(5, len(scored_citizens))]
                self.current_dwarf_index = (self.current_dwarf_index + 1) % len(top_pool)
                target_score, target = top_pool[self.current_dwarf_index]

                logging.info(f"Timed Rotation: Cycling focus to {target.get('name')} "
                             f"(Score: {target_score:.1f}, Profession: {target.get('profession')})")
                self.last_rotation_time = now
                self.active_unit_id = target.get("id")
                return self.active_unit_id
            return None

        # 3. Legacy Event-driven mode
        if self.mode == "event":
            highly_stressed = [d for score, d in scored_citizens if d.get("stress", 0) > 10000]
            if highly_stressed:
                most_stressed = max(highly_stressed, key=lambda d: d.get("stress", 0))
                if most_stressed.get("id") != self.active_unit_id:
                    logging.info(f"Event Mode: Snapping focus to stressed dwarf {most_stressed.get('name')}")
                    self.last_rotation_time = now
                    self.active_unit_id = most_stressed.get("id")
                    return self.active_unit_id
                return None

            strange_mood_jobs = ["Strange Mood", "Fell Mood", "Secret Mood", "Possessed", "Macabre"]
            moody = [d for score, d in scored_citizens
                     if any(m in (d.get("current_job") or "") for m in strange_mood_jobs)]
            if moody:
                target = moody[0]
                if target.get("id") != self.active_unit_id:
                    logging.info(f"Event Mode: Snapping focus to moody dwarf {target.get('name')}")
                    self.last_rotation_time = now
                    self.active_unit_id = target.get("id")
                    return self.active_unit_id
        return None

    def set_mode(self, new_mode):
        with self.lock:
            if new_mode not in ["director", "timed", "event", "idle"]:
                return
            if new_mode == self.mode:
                return  # key repeat should not flood the log
            self.mode = new_mode
            logging.info(f"Antfarm mode changed to: {new_mode}")
            if new_mode == "idle":
                self.client.unfocus()
