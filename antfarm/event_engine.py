import time
import math
import logging
import threading

class DFEvent:
    def __init__(self, name, weight=100, half_life=60, payload=None):
        self.name = name
        self.weight = weight
        self.half_life = half_life  # in seconds
        self.payload = payload or {}
        self.timestamp = time.time()

    def get_current_interest(self, current_time):
        dt = current_time - self.timestamp
        if dt < 0:
            return self.weight
        # Exponential decay: weight * 2^(-dt / half_life)
        decay_factor = math.pow(2.0, -dt / self.half_life)
        return self.weight * decay_factor

class EventBus:
    def __init__(self):
        self._subscribers = {}
        self.lock = threading.Lock()
        
    def subscribe(self, event_name, callback):
        with self.lock:
            if event_name not in self._subscribers:
                self._subscribers[event_name] = []
            self._subscribers[event_name].append(callback)
            
    def unsubscribe(self, event_name, callback):
        with self.lock:
            if event_name in self._subscribers:
                if callback in self._subscribers[event_name]:
                    self._subscribers[event_name].remove(callback)
                    
    def publish(self, event):
        callbacks = []
        with self.lock:
            if event.name in self._subscribers:
                callbacks.extend(self._subscribers[event.name])
            if "*" in self._subscribers:
                callbacks.extend(self._subscribers["*"])
                
        for cb in callbacks:
            try:
                cb(event)
            except Exception as e:
                logging.error(f"Error in EventBus subscriber: {e}")

class EventEngine:
    def __init__(self, event_bus: EventBus):
        self.event_bus = event_bus
        self.last_state = None
        self.dwarf_jobs = {}
        self.dwarf_stress = {}
        self.last_announcement = None
        
    def process_state(self, state):
        if not state:
            return

        unit_data = state.get("unit_data")
        citizens = state.get("citizens") or []
        announcements = state.get("announcements") or []

        # The server publishes an empty roster whenever no map is loaded -- the
        # player quitting to the main menu, or a save being swapped. Diffing
        # against that would report every dwarf in the fortress as dead at once,
        # which the Twitch bridge would then announce to chat and open a death
        # poll about. Treat it as "no information", not "everyone died".
        if not state.get("map_loaded", True):
            self.last_state = None
            return
        if not citizens and self.last_state and (self.last_state.get("citizens") or []):
            logging.info("Roster came back empty; skipping the diff rather than "
                         "reporting a fortress-wide death.")
            self.last_state = None
            return
        
        # 1. Process Announcements
        if announcements:
            latest_ann = announcements[0]
            if latest_ann != self.last_announcement:
                self.last_announcement = latest_ann
                self.event_bus.publish(DFEvent(
                    name="FortressAnnouncement",
                    weight=300,
                    half_life=120,
                    payload={"text": latest_ann}
                ))
                
        # 2. Compare Roster to Detect Events
        for d in citizens:
            d_id = d.get("id")
            name = d.get("name")
            job = d.get("current_job", "Idle")
            stress = d.get("stress", 0)
            
            # Detect Job Changes
            old_job = self.dwarf_jobs.get(d_id, "Idle")
            if old_job != job:
                self.dwarf_jobs[d_id] = job
                
                # Check for Job Commencement
                if old_job == "Idle" and job != "Idle":
                    # Check if combat
                    if any(c in job for c in ["Fight", "Combat", "Attack", "Soldier"]):
                        self.event_bus.publish(DFEvent(
                            name="CitizenEnteredCombat",
                            weight=1000,
                            half_life=300,
                            payload={"id": d_id, "name": name, "job": job}
                        ))
                    else:
                        self.event_bus.publish(DFEvent(
                            name="CitizenStartedJob",
                            weight=100,
                            half_life=30,
                            payload={"id": d_id, "name": name, "job": job}
                        ))
                elif old_job != "Idle" and job == "Idle":
                    self.event_bus.publish(DFEvent(
                        name="CitizenFinishedJob",
                        weight=50,
                        half_life=15,
                        payload={"id": d_id, "name": name, "job": old_job}
                    ))
                    
            # Detect Stress Increases
            old_stress = self.dwarf_stress.get(d_id, 0)
            if old_stress != stress:
                self.dwarf_stress[d_id] = stress
                if stress > old_stress and stress > 10000:
                    self.event_bus.publish(DFEvent(
                        name="CitizenStressIncreased",
                        weight=400,
                        half_life=180,
                        payload={"id": d_id, "name": name, "stress": stress, "diff": stress - old_stress}
                    ))
                    
        # 3. Detect departures from the roster.
        #
        # A dwarf leaving the citizen list has NOT necessarily died. Banishment,
        # a merchant escort going home, a werebeast transforming, a prisoner
        # taken off-site and a militia squad marching off the edge all look
        # identical from here, and announcing every one of them as "X has died!"
        # in chat -- and opening a memorial poll about it -- was a steady source
        # of false alarms.
        #
        # DF does announce real deaths, so a death is corroborated: the dwarf is
        # gone AND their name appears in a recent announcement. Anything else is
        # reported as a departure, which the Twitch bridge does not announce.
        if self.last_state:
            old_citizens = self.last_state.get("citizens", [])
            old_ids = {c.get("id") for c in old_citizens}
            new_ids = {c.get("id") for c in citizens}
            recent = " ".join(announcements).lower()

            for old_id in old_ids:
                if old_id in new_ids:
                    continue
                old_name = next((c.get("name") for c in old_citizens
                                 if c.get("id") == old_id), "Unknown Dwarf")
                named = old_name and old_name.lower() in recent
                # DF's death announcements read "<name> has died", "... has been
                # struck down", "... has bled to death", or name a slain victim.
                death_words = ("died", "slain", "struck down", "bled to death",
                               "has been killed", "murdered", "drowned",
                               "starved", "died of thirst")
                looks_dead = named and any(w in recent for w in death_words)

                if looks_dead:
                    self.event_bus.publish(DFEvent(
                        name="CitizenDeath",
                        weight=2000,  # Max weight for death!
                        half_life=600,
                        payload={"id": old_id, "name": old_name}
                    ))
                else:
                    self.event_bus.publish(DFEvent(
                        name="CitizenDeparted",
                        weight=300,
                        half_life=300,
                        payload={"id": old_id, "name": old_name}
                    ))
                    
        self.last_state = state
