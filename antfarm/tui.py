import sys
import os
import sqlite3
import logging
import time
from collections import OrderedDict
from rich.markup import escape
from textual.app import App, ComposeResult
from textual.widgets import Footer, Static
from textual.containers import Container, Grid, Vertical

from antfarm.client import DFClient
from antfarm.engine import AntfarmEngine

# Set logging to file to avoid stdout corruption
logging.basicConfig(filename="antfarm.log", level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

# The Legends archive is generated from a world export, not shipped: it lives
# in state/ with the other runtime data.
DB_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "state", "legends.db")

def query_legends_db(hist_id):
    if not os.path.exists(DB_PATH):
        return None, []
        
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        c.execute("SELECT name, birth_year, race, death_year FROM historical_figures WHERE id = ?", (hist_id,))
        hf_row = c.fetchone()
        
        if not hf_row:
            conn.close()
            return None, []
            
        hf_data = {
            "name": hf_row[0],
            "birth_year": hf_row[1],
            "race": hf_row[2],
            "death_year": hf_row[3]
        }
        
        c.execute("""
            SELECT r.relation_type, hf.name, hf.id
            FROM relationships r
            JOIN historical_figures hf ON r.hf_id_2 = hf.id
            WHERE r.hf_id_1 = ?
        """, (hist_id,))
        relations = []
        for row in c.fetchall():
            relations.append({
                "type": row[0],
                "name": row[1],
                "id": row[2]
            })
            
        conn.close()
        return hf_data, relations
    except Exception as e:
        logging.error(f"Error querying SQLite: {e}")
        return None, []

def render_progress_bar(value, max_value, width=15, color="cyan"):
    if max_value <= 0:
        return "░" * width
    percent = min(1.0, max(0.0, value / max_value))
    filled_len = int(percent * width)
    empty_len = width - filled_len
    
    block_char = "█"
    empty_char = "░"
    
    if color in ["pink", "magenta", "#FF2D95"]:
        return f"[bold #FF2D95]{block_char * filled_len}[/][grey37]{empty_char * empty_len}[/]"
    elif color in ["yellow", "warning", "#FFC857"]:
        return f"[bold #FFC857]{block_char * filled_len}[/][grey37]{empty_char * empty_len}[/]"
    elif color in ["red", "danger", "#FF4040"]:
        return f"[bold #FF4040]{block_char * filled_len}[/][grey37]{empty_char * empty_len}[/]"
    elif color in ["green", "success", "#59FF8E"]:
        return f"[bold #59FF8E]{block_char * filled_len}[/][grey37]{empty_char * empty_len}[/]"
    else:
        return f"[bold #00F5FF]{block_char * filled_len}[/][grey37]{empty_char * empty_len}[/]"

# Real per-dwarf stress history, so the sparkline shows what actually happened
# rather than a shape derived from the current value.
#
# An OrderedDict used as an LRU: the previous code dropped the 100 oldest keys
# by insertion order whenever the table passed 400, which evicted long-lived
# dwarves the camera keeps returning to and kept one-off migrants who had died
# an hour earlier.
_STRESS_HISTORY = OrderedDict()
_STRESS_HISTORY_LEN = 24
_STRESS_HISTORY_MAX = 400
_STRESS_SAMPLE_SEC = 2.0
_last_stress_sample = OrderedDict()

SPARK_CHARS = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

def record_stress(unit_id, stress):
    if unit_id is None:
        return
    now = time.time()
    if now - _last_stress_sample.get(unit_id, 0) < _STRESS_SAMPLE_SEC:
        return
    _last_stress_sample[unit_id] = now
    _last_stress_sample.move_to_end(unit_id)
    history = _STRESS_HISTORY.setdefault(unit_id, [])
    _STRESS_HISTORY.move_to_end(unit_id)
    history.append(stress)
    if len(history) > _STRESS_HISTORY_LEN:
        del history[:-_STRESS_HISTORY_LEN]
    # Keep the table from growing without bound over a long stream, evicting
    # whichever dwarf has gone longest without a sample.
    while len(_STRESS_HISTORY) > _STRESS_HISTORY_MAX:
        stale, _ = _STRESS_HISTORY.popitem(last=False)
        _last_stress_sample.pop(stale, None)
    while len(_last_stress_sample) > _STRESS_HISTORY_MAX * 2:
        _last_stress_sample.popitem(last=False)

def get_stress_sparkline(stress, unit_id=None):
    history = list(_STRESS_HISTORY.get(unit_id, [])) if unit_id is not None else []
    if not history:
        history = [stress]

    # Scale against the observed range so small real swings stay visible;
    # fall back to DF's nominal -100k..100k band when the dwarf is flat.
    low, high = min(history), max(history)
    if high - low < 1000:
        low, high = -100000, 100000
    span = max(1, high - low)

    out = []
    for value in history[-_STRESS_HISTORY_LEN:]:
        level = int((value - low) / span * (len(SPARK_CHARS) - 1))
        out.append(SPARK_CHARS[max(0, min(len(SPARK_CHARS) - 1, level))])
    return "".join(out)

def _thought_words(t):
    """emotion/thought as display strings.

    Both come straight out of DF via the Lua serialiser. `emotion` has always
    been a string in practice, but `.capitalize()` on a None raises and takes
    the whole panel down, and a panel that stops repainting on a live stream is
    indistinguishable from a hung dashboard.
    """
    emotion = (t.get("emotion") or "Feeling")
    thought = (t.get("thought") or "something")
    return escape(str(emotion).capitalize()), escape(str(thought))


def generate_story_narrative(unit, announcements):
    if not unit:
        return "Waiting for a citizen to focus on..."

    # Dwarf names, jobs and professions are game text and can contain square
    # brackets. Rich reads those as markup tags: at best the text vanishes, at
    # worst update() raises MarkupError and the panel freezes.
    name = escape(str(unit.get("name") or "Unknown Dwarf"))
    job = escape(str(unit.get("current_job") or "Idle"))
    stress = unit.get("stress", 0) or 0
    prof = escape(str(unit.get("profession") or "Citizen"))
    thoughts = unit.get("thoughts", [])
    
    narrative = f"[bold #FF2D95]{name}[/] is a [cyan]{prof}[/] who is currently [bold white]{job.lower()}[/].\n"
    
    strange_moods = ["Strange Mood", "Fell Mood", "Secret Mood", "Possessed", "Macabre"]
    if any(m in job for m in strange_moods):
        narrative += f"[bold #FF4040]URGENT ALERT:[/] {name} has entered a {job}! They are gathering materials for a craft. Failure to locate necessary items will drive them permanently insane."
        return narrative
        
    if stress > 50000:
        narrative += f"They are experiencing [bold #FF4040]severe emotional stress[/] (Stress: {stress}). "
        if thoughts:
            emotion, thought = _thought_words(thoughts[0])
            narrative += f"They recently felt [bold #FF4040]{emotion}[/] because of {thought}. "
        narrative += "They require rest or socialization to prevent an imminent mental meltdown."
    elif stress > 10000:
        narrative += f"They are currently [bold #FFC857]stressed[/]. "
        if thoughts:
            emotion, thought = _thought_words(thoughts[0])
            narrative += f"They are preoccupied with feeling {emotion} about {thought}."
    else:
        narrative += f"They are in [bold #59FF8E]excellent spirits[/] and satisfied with fortress life. "
        if thoughts:
            emotion, thought = _thought_words(thoughts[0])
            narrative += f"They recently felt {emotion} after {thought}."
            
    if any(c in job for c in ["Fight", "Combat", "Attack", "Soldier"]):
        narrative += f"\n[bold #FF4040]COMBAT STATUS:[/] Engaging enemies in active combat!"
        
    return narrative

class HeaderWidget(Static):
    def update_stats(self, stats, mode, active_unit_name=None, active_unit_job=None,
                     active_interest=0, twitch=None, build=None, ui=None):
        logo = (
            "[bold #00F5FF] ___  ___  [/][bold #FF2D95]  ___ ___  __  __ ___  _   _  _  ___  _  _ [/]\n"
            "[bold #00F5FF]|   \\| __| [/][bold #FF2D95] / __/ _ \\|  \\/  | _ \\/_\\ | \\| |/ _ \\| \\| |[/]\n"
            "[bold #00F5FF]| |) | _|  [/][bold #FF2D95]| (_| (_) | |\\/| |  _/ _ \\| .` | (_) | .` |[/]\n"
            "[bold #00F5FF]|___/|_|   [/][bold #FF2D95] \\___\\___/|_|  |_|_|/_/ \\_\\_|\\_|\\___/|_|\\_|[/]"
        )
        
        if not stats:
            # Render waiting status banner
            banner = f"[bold #B64CFF]DIRECTOR MODE:[/] [bold #FFC857]{mode.upper()}[/] | [bold #FF4040]▲ OFFLINE[/] | IPC: [bold #FFC857]WAITING FOR GAME SAVE TO LOAD...[/]"
            self.update(
                f"{logo}    [bold #FF4040]DISCONNECTED[/]\n"
                f"───────────────────────────────────────────────────────────────────────────\n"
                f"{banner}"
            )
            return

        pop = stats.get("pop", 0)
        year = stats.get("year", 0)
        season = stats.get("season", "Spring")
        fps = int(stats.get("fps", 0))
        
        following_str = escape(str(active_unit_name or "NONE"))
        reason_str = escape(str(active_unit_job or "IDLE"))
        
        banner = (
            f"[bold #B64CFF]DIRECTOR MODE:[/] [bold #59FF8E]{mode.upper()}[/] | "
            f"[bold #B64CFF]FOLLOWING:[/] [bold white]{following_str}[/] | "
            f"[bold #B64CFF]REASON:[/] [bold #FFC857]{reason_str}[/] | "
            f"[bold #B64CFF]INTEREST:[/] [bold #00F5FF]{int(active_interest)}[/]"
        )
        
        if twitch is None:
            twitch_line = "[grey37]CHAT OFF[/]"
        elif twitch:
            twitch_line = "[bold #B64CFF]CHAT LIVE[/]"
        else:
            twitch_line = "[bold #FFC857]CHAT ...[/]"

        stats_line = (
            f"[bold #00F5FF]POPULATION:[/] [bold white]{pop}[/] | "
            f"[bold #00F5FF]YEAR:[/] [bold white]{year}[/] ({season}) | "
            f"[bold #00F5FF]FPS:[/] [bold white]{fps}[/] | {twitch_line}"
        )
        if build:
            if not build.get("anchored"):
                build_line = ("[bold #FFC857]BUILD:[/] [grey37]not anchored "
                              "(antfarm_blueprint autostart)[/]")
            elif build.get("stalled"):
                # A stalled build looks exactly like a slow one on the old
                # display: the step number simply stopped changing, with nothing
                # saying why. Say it outright.
                build_line = (
                    f"[bold #FF4040]BUILD STALLED:[/] [bold white]"
                    f"{build.get('step')}/{build.get('total')}[/] "
                    f"{escape(str(build.get('label','')))} - "
                    f"[#FF4040]{escape(str(build.get('stall_reason','')))}[/]"
                )
            else:
                ready = ("[bold #59FF8E]READY[/]" if build.get("ready")
                         else f"[grey37]{escape(str(build.get('status','')))}[/]")
                warn = ""
                if build.get("warnings"):
                    warn = f"  [#FFC857]!{len(build['warnings'])}[/]"
                build_line = (
                    f"[bold #FFC857]BUILD:[/] [bold white]{build.get('step')}/{build.get('total')}[/] "
                    f"{escape(str(build.get('label','')))} {ready}"
                    f"{'  [bold #B64CFF]AUTO[/]' if build.get('auto') else ''}{warn}"
                )
            stats_line += f"\n{build_line}"

        # The modal watchdog. Without this line an auto-dismissed cavern popup
        # or a fort held on a diplomat screen happened entirely invisibly.
        if ui:
            if ui.get("pending_popups", 0) > 0:
                ui_line = (f"[bold #FF4040]BLOCKED:[/] {ui['pending_popups']} popup(s) "
                           f"awaiting dismissal")
            elif not ui.get("drivable", True):
                ui_line = (f"[bold #FFC857]SCREEN:[/] "
                           f"{escape(str(ui.get('screen','?')))}"
                           f"{'  [#FF4040]PAUSED[/]' if ui.get('paused') else ''}")
            else:
                log = ui.get("log") or []
                last = escape(str(log[-1].get("text", ""))) if log else ""
                ui_line = (f"[bold #59FF8E]WATCHDOG:[/] [grey37]"
                           f"{ui.get('popups_dismissed', 0)} popup(s), "
                           f"{ui.get('screens_dismissed', 0)} screen(s)"
                           f"{'  |  ' + last[:70] if last else ''}[/]")
            stats_line += f"\n{ui_line}" 
        
        self.update(
            f"{logo}    {stats_line}\n"
            f"───────────────────────────────────────────────────────────────────────────\n"
            f"{banner}"
        )

class DwarfIdentityWidget(Static):
    def on_mount(self):
        self.border_title = "CITIZEN PROFILE"
        
    def update_unit(self, unit):
        if not unit:
            self.update(
                f"  [bold #FFC857]▲ WAITING FOR FORTRESS...[/]\n\n"
                f"  • Connect Status: [yellow]SCANNING[/]\n"
                f"  • Save Status:    [yellow]NOT LOADED[/]"
            )
            return
            
        name = escape(str(unit.get("name") or "Unknown Dwarf"))
        prof = escape(str(unit.get("profession") or "Peasant"))
        age = unit.get("age", 0)
        gender = unit.get("gender") or "unknown"
        stress = unit.get("stress", 0) or 0
        
        stress_desc = "Ecstatic"
        stress_color = "#59FF8E"
        if stress > 50000:
            stress_desc = "Miserable"
            stress_color = "#FF4040"
        elif stress > 10000:
            stress_desc = "Stressed"
            stress_color = "#FFC857"
        elif stress > 0:
            stress_desc = "Content"
            stress_color = "#00F5FF"
            
        record_stress(unit.get("id"), stress)
        sparkline = get_stress_sparkline(stress, unit.get("id"))
        
        portrait_lines = [
            "  ┌─────────┐  ",
            "  │    ☼    │  ",
            "  │  DWARF  │  ",
            "  └─────────┘  "
        ]
        
        info_lines = [
            f"[bold white]NAME:[/] [bold #FF2D95]{name.upper()}[/]",
            f"[bold white]TITLE:[/] [bold #00F5FF]{prof}[/]",
            f"[bold white]STATS:[/] Age {age} | {gender.capitalize()}",
            f"[bold white]STRESS:[/] {stress} ([bold {stress_color}]{stress_desc}[/])",
            f"[bold white]TREND:[/] {sparkline}"
        ]
        
        content_lines = []
        for i in range(max(len(portrait_lines), len(info_lines))):
            p_line = portrait_lines[i] if i < len(portrait_lines) else "               "
            i_line = info_lines[i] if i < len(info_lines) else ""
            content_lines.append(f"{p_line}{i_line}")
            
        self.update("\n".join(content_lines))

class DwarfActivityWidget(Static):
    def on_mount(self):
        self.border_title = "FORTRESS ACTIVITY"
        
    def update_activity(self, unit, announcements):
        if not unit:
            self.update(
                f"  [bold #FFC857]▲ SCANNING FOR EVENTS...[/]\n\n"
                f"  • IPC Bridge:     [grey37]Listening[/]\n"
                f"  • Active Alerts:  [grey37]Offline[/]"
            )
            return
            
        job = escape(str(unit.get("current_job") or "Idle"))
        pos = unit.get("pos", {"x": 0, "y": 0, "z": 0})
        thoughts = unit.get("thoughts", [])
        
        thoughts_str = ""
        if thoughts:
            for t in thoughts[:2]:
                emotion, thought = _thought_words(t)
                thoughts_str += f"• [bold #FF2D95]{emotion}:[/] [cyan]{thought}[/]\n"
        else:
            thoughts_str = "• No notable emotional memories.\n"

        ann_str = ""
        if announcements:
            for a in announcements[:2]:
                # DF announcement text is arbitrary game text; escape it before
                # Rich tries to read a bracketed word as a markup tag.
                ann_str += f"• [bold white]{escape(str(a))}[/]\n"
        else:
            ann_str = "• No recent announcements.\n"
            
        self.update(
            f"[cyan]ACTION:[/] [bold white]{job}[/] | [cyan]COORDS:[/] X:{pos.get('x')} Y:{pos.get('y')} Z:{pos.get('z')}\n\n"
            f"[cyan]RECENT EMOTIONS:[/]\n{thoughts_str}\n"
            f"[cyan]LIVE EVENT FEED:[/]\n{ann_str}"
        )

class DwarfStatsWidget(Static):
    def on_mount(self):
        self.border_title = "GAUGES & SKILLS"
        
    def update_unit(self, unit):
        if not unit:
            self.update(
                f"  [bold #FFC857]▲ WAITING FOR DATA...[/]\n\n"
                f"  • Gauges: [grey37]0 / 100[/]\n"
                f"  • Skills: [grey37]None[/]"
            )
            return
            
        attrs = unit.get("attributes", {})
        phys = attrs.get("physical", {})
        
        strength = phys.get("STRENGTH", 1000)
        agility = phys.get("AGILITY", 1000)
        toughness = phys.get("TOUGHNESS", 1000)
        
        str_bar = render_progress_bar(strength, 2000, width=12, color="#00F5FF")
        agi_bar = render_progress_bar(agility, 2000, width=12, color="#00F5FF")
        tgh_bar = render_progress_bar(toughness, 2000, width=12, color="#00F5FF")
        
        needs_list = unit.get("needs", [])
        needs_dict = {n.get("type"): n.get("level", 0) for n in needs_list}
        
        sleep_lvl = needs_dict.get("sleep", 0)
        drink_lvl = needs_dict.get("drink", 0)
        food_lvl = needs_dict.get("food", 0)
        
        sleep_bar = render_progress_bar(sleep_lvl, 1000, width=12, color="#FF2D95")
        drink_bar = render_progress_bar(drink_lvl, 1000, width=12, color="#00F5FF")
        food_bar = render_progress_bar(food_lvl, 1000, width=12, color="#FFC857")
        
        skills = unit.get("skills", [])
        skills_str = ""
        if skills:
            for s in skills[:3]:
                rating_val = s.get("rating", 0)
                bar = render_progress_bar(rating_val, 15, width=12, color="#B64CFF")
                skills_str += f"• [cyan]{s.get('name')[:12]}:[/] {rating_val}/15 {bar}\n"
        else:
            skills_str = "• No notable training.\n"
            
        self.update(
            f"[cyan]SLEEP:[/]   {sleep_bar} | [cyan]FOOD:[/]  {food_bar}\n"
            f"[cyan]ALCOHOL:[/] {drink_bar} | [cyan]STR:[/]   {str_bar}\n"
            f"[cyan]AGI:[/]     {agi_bar} | [cyan]TGH:[/]   {tgh_bar}\n"
            f"──────────────────────────────────────────────────\n"
            f"[cyan]TOP SKILLS:[/]\n{skills_str}"
        )

class DwarfLoreWidget(Static):
    # Evicting one entry at a time keeps the cache warm. Clearing all 256 at
    # once meant the next 256 distinct dwarves each cost a synchronous SQLite
    # query against the 23MB legends database, on the thread that paints the
    # dashboard -- a visible stall right after the cache filled.
    LORE_CACHE_MAX = 256

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.lore_cache = OrderedDict()
        
    def on_mount(self):
        self.border_title = "LORE & RELATIONSHIPS"
        
    def update_unit(self, unit):
        if not unit:
            self.update(
                f"  [bold #FFC857]▲ WAITING FOR LORE...[/]\n\n"
                f"  • Database: [cyan]Legends SQLite Ready[/]"
            )
            return
            
        hist_id = unit.get("hist_id", -1)
        if hist_id is None or hist_id < 0:
            # Plenty of citizens have no historical figure; there is nothing to
            # look up and caching under -1 would pin one dwarf's miss forever.
            hf_data, relations = None, []
        else:
            if hist_id in self.lore_cache:
                self.lore_cache.move_to_end(hist_id)
            else:
                self.lore_cache[hist_id] = query_legends_db(hist_id)
                while len(self.lore_cache) > self.LORE_CACHE_MAX:
                    self.lore_cache.popitem(last=False)
            hf_data, relations = self.lore_cache[hist_id]
        
        rel_icons = {
            "spouse": "♥",
            "child": "👶",
            "parent": "👪",
            "sibling": "🤝",
            "friend": "☺",
            "enemy": "⚔",
            "mentor": "⚒",
            "apprentice": "⚒"
        }
        
        rel_str = ""
        if relations:
            for r in relations[:3]:
                rtype = (r.get("type") or "relation").lower()
                icon = rel_icons.get(rtype, "•")
                rel_str += (f"{icon} [bold #FF2D95]{escape(str(r.get('type')))}:[/] "
                            f"[cyan]{escape(str(r.get('name')))}[/]\n")
        else:
            rel_str = "• No family relationships recorded.\n"
            
        timeline = "Born ➔ Migrated ➔ Active Citizen"
        if hf_data:
            birth_year = hf_data.get("birth_year", 0)
            timeline = f"Born (Year {birth_year}) ➔ Migrated ➔ Active Citizen"
            
        self.update(
            f"{rel_str}"
            f"──────────────────────────────────────────────────\n"
            f"[bold #FF2D95]LIFE TIMELINE:[/]\n"
            f" {timeline}"
        )

class StoryCardWidget(Static):
    def on_mount(self):
        self.border_title = "CURRENT STORY CARD"
        
    def update_story(self, unit, announcements):
        if not unit:
            self.update(
                f"  [bold #00F5FF]WELCOME TO DF COMPANION OBSERVER 2.0[/]\n"
                f"  The system is running and listening on the JSON-file IPC bridge.\n"
                f"  Launch Dwarf Fortress and load a save game to begin streaming live citizen stories."
            )
            return
            
        narrative = generate_story_narrative(unit, announcements)
        self.update(narrative)

class AntfarmApp(App):
    CSS = """
    Screen {
        background: #05070D;
        padding: 2;
    }
    
    #main-container {
        layout: vertical;
        height: 100%;
    }
    
    #header-bar {
        height: 8;
        background: #0D1120;
        color: white;
        border: solid #B64CFF;
        content-align: center middle;
        padding: 0 1;
        margin-bottom: 1;
    }
    
    #center-layout {
        layout: grid;
        grid-size: 2;
        grid-columns: 45% 55%;
        height: 1fr;
        min-height: 20;
        margin-bottom: 1;
    }
    
    #story-card-panel {
        height: 8;
        background: #0D1120;
        border: solid #B64CFF;
        padding: 1 2;
    }
    
    .column-left {
        layout: vertical;
        margin-right: 1;
    }
    
    .column-right {
        layout: vertical;
    }
    
    .panel {
        background: #0D1120;
        margin-bottom: 1;
        padding: 1 2;
        height: 1fr;
        overflow-y: auto;
    }
    
    .column-left .panel {
        border: solid #00F5FF;
    }
    
    .column-right .panel {
        border: solid #FF2D95;
    }
    """
    
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("d", "mode_director", "Mode: Director"),
        ("t", "mode_timed", "Mode: Timed"),
        ("e", "mode_event", "Mode: Event"),
        ("i", "mode_idle", "Mode: Idle"),
        ("r", "rotate", "Rotate Camera"),
        ("b", "trigger_blueprint", "Build: next step"),
        ("B", "trigger_blueprint_auto", "Build: auto on/off"),
        ("u", "unblock", "Unblock: dismiss popup/screen"),
    ]
    
    def __init__(self, client: DFClient, engine: AntfarmEngine, twitch=None):
        super().__init__()
        self.client = client
        self.engine = engine
        self.twitch = twitch
        self._last_ui_error_log = 0.0
        
    def compose(self) -> ComposeResult:
        yield Container(
            HeaderWidget(id="header-bar"),
            Grid(
                Vertical(
                    DwarfIdentityWidget(id="identity-panel", classes="panel"),
                    DwarfStatsWidget(id="stats-panel", classes="panel"),
                    classes="column-left"
                ),
                Vertical(
                    DwarfActivityWidget(id="activity-panel", classes="panel"),
                    DwarfLoreWidget(id="lore-panel", classes="panel"),
                    classes="column-right"
                ),
                id="center-layout"
            ),
            StoryCardWidget(id="story-card-panel"),
            id="main-container"
        )
        yield Footer()
        
    def on_mount(self) -> None:
        self.client.add_state_callback(self._on_state_update)
        self.set_interval(0.5, self._tick)
        
    def _twitch_status(self):
        """None = not configured, False = connecting, True = in chat."""
        if not self.twitch or not self.twitch.running:
            return None
        return bool(self.twitch.connected)

    def on_unmount(self) -> None:
        # Release the camera now instead of making the player wait out the Lua
        # heartbeat, and close the chat socket cleanly.
        try:
            if self.twitch:
                self.twitch.stop()
        except Exception:
            pass
        try:
            self.engine.stop()
            self.client.disconnect()
        except Exception:
            pass

    def _tick(self) -> None:
        self._update_ui()
        
    def _on_state_update(self, payload):
        # Deliberately does NOT call_from_thread(_update_ui): that blocks the
        # DFClient listener until six panels have rendered, including a
        # synchronous query against the 23MB legends database on a lore cache
        # miss. The listener would fall behind the 200ms state stream, delaying
        # the auto-unpause and auto-defence checks that run off it. The 0.5s
        # set_interval already repaints.
        pass
        
    def _update_ui(self) -> None:
        if not self.is_mounted:
            return
        try:
            state = self.client.latest_state
            if not state:
                self.query_one("#header-bar", HeaderWidget).update_stats(
                    stats={},
                    mode=self.engine.mode,
                    active_unit_name="OFFLINE",
                    active_unit_job="WAITING FOR STATE",
                    active_interest=0,
                    twitch=self._twitch_status(),
                )
                self.query_one("#identity-panel", DwarfIdentityWidget).update_unit(None)
                self.query_one("#activity-panel", DwarfActivityWidget).update_activity(None, [])
                self.query_one("#stats-panel", DwarfStatsWidget).update_unit(None)
                self.query_one("#lore-panel", DwarfLoreWidget).update_unit(None)
                self.query_one("#story-card-panel", StoryCardWidget).update_story(None, [])
                return
                
            stats = state.get("fortress_stats", {})
            unit = state.get("unit_data")
            announcements = state.get("announcements", [])
            
            active_name = None
            active_job = None
            active_interest = 0
            if unit:
                active_name = unit.get("name")
                active_job = unit.get("current_job")
                # Score it exactly as the Director does. This used to omit
                # density and relations, so the INTEREST figure on screen was
                # systematically lower than the number actually steering the
                # camera -- the dashboard disagreed with the thing it reports on.
                active_interest = self.engine.score_citizen(unit)

            self.query_one("#header-bar", HeaderWidget).update_stats(
                stats=stats,
                mode=self.engine.mode,
                active_unit_name=active_name,
                active_unit_job=active_job,
                active_interest=active_interest,
                twitch=self._twitch_status(),
                build=state.get("build"),
                ui=state.get("ui"),
            )
            self.query_one("#identity-panel", DwarfIdentityWidget).update_unit(unit)
            self.query_one("#activity-panel", DwarfActivityWidget).update_activity(unit, announcements)
            self.query_one("#stats-panel", DwarfStatsWidget).update_unit(unit)
            self.query_one("#lore-panel", DwarfLoreWidget).update_unit(unit)
            self.query_one("#story-card-panel", StoryCardWidget).update_story(unit, announcements)
        except Exception as e:
            # Was logging.debug, which the INFO-level root logger discards
            # outright -- a persistent error froze the dashboard on stale
            # content with nothing in antfarm.log. Rate-limited so a per-frame
            # failure cannot fill the file.
            now = time.time()
            if now - self._last_ui_error_log > 10.0:
                self._last_ui_error_log = now
                logging.error(f"UI update failed: {e}", exc_info=True)
        
    def action_mode_director(self) -> None:
        self.engine.clear_override()
        self.engine.set_mode("director")
        self._update_ui()
        
    def action_mode_timed(self) -> None:
        self.engine.set_mode("timed")
        self._update_ui()
        
    def action_mode_event(self) -> None:
        self.engine.set_mode("event")
        self._update_ui()
        
    def action_mode_idle(self) -> None:
        self.engine.set_mode("idle")
        self._update_ui()
        
    def action_rotate(self) -> None:
        if self.engine.mode == "timed":
            self.engine.clear_override()
            self.engine.last_rotation_time = 0
            logging.info("TUI: Triggered manual camera rotation in Timed mode.")
            self._update_ui()
            
    def action_trigger_blueprint(self) -> None:
        self.client.build_command("next")
        logging.info("TUI: Requested the next step of the guided Dreamfort build.")

    def action_unblock(self) -> None:
        """Dismiss whatever the fort is stopped on, without leaving the dashboard.

        The watchdog does this on its own; this is the manual override for the
        case it has given up on, so an operator does not have to alt-tab into
        the game and find the window.
        """
        self.client.send_cmd("ui dismiss")
        logging.info("TUI: asked the watchdog to dismiss the current blocker.")

    def action_trigger_blueprint_auto(self) -> None:
        # The engine mirrors the server's view of whether auto mode is running.
        build = (self.client.latest_state or {}).get("build") or {}
        self.client.build_command("auto off" if build.get("auto") else "auto on")
        logging.info("TUI: Toggled guided-build auto mode.")

def main():
    try:
        # Instantiate and connect IPC client and Antfarm engine
        client = DFClient()
        engine = AntfarmEngine(client)
        
        client.connect()
        engine.start()

        # Twitch is optional: with no credentials configured the bridge stays
        # dormant and the dashboard runs exactly as before.
        twitch = None
        try:
            from antfarm.twitch import TwitchBridge
            bridge = TwitchBridge(client, engine)
            if bridge.start():
                twitch = bridge
        except Exception as e:
            logging.error(f"Twitch bridge unavailable: {e}")

        # Start textual application run loop
        app = AntfarmApp(client, engine, twitch=twitch)
        app.run()
    except Exception as e:
        sys.stderr.write(f"CRITICAL: Failed to launch DF Companion: {e}\n")
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
