"""Twitch chat bridge for Antfarm mode.

Turns the fortress into a terrarium the audience can poke: viewers steer the
Director AI's camera, claim migrants as their own dwarves, pull stat readouts,
and vote in polls that open automatically when something dramatic happens.

Transport is plain Twitch IRC over TLS -- no third-party dependency, because the
venv only carries textual/rich and the stream box should not need more.

Configuration, checked in this order:
  1. environment: TWITCH_NICK, TWITCH_TOKEN, TWITCH_CHANNEL
  2. config/twitch.json: {"nick": ..., "token": ..., "channel": ...}

The token is a chat OAuth token and must carry its "oauth:" prefix. Generate one
for the bot account at https://twitchapps.com/tmi/ (scope: chat:read chat:edit).

Run standalone against a live fortress:
    ./.venv/bin/python -m antfarm.twitch
"""

import concurrent.futures
import json
import logging
import os
import random
import re
import socket
import ssl
import threading
import time

# Credentials and per-viewer state live outside the package: `antfarm/` is code
# that goes in the repository, `config/` and `state/` are the operator's and are
# gitignored. Keeping a chat token inside the importable package was one
# `git add -f` away from being published.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(_ROOT, "config", "twitch.json")
CLAIMS_PATH = os.path.join(_ROOT, "state", "claims.json")

IRC_HOST = "irc.chat.twitch.tv"
IRC_PORT = 6697

# Twitch disconnects a non-moderator bot that exceeds 20 messages per 30s.
# Staying at 18 leaves room for the PONGs.
RATE_LIMIT_MESSAGES = 18
RATE_LIMIT_WINDOW = 30.0

USER_COOLDOWN = 8.0        # seconds between commands from one viewer
CAMERA_COOLDOWN = 20.0     # seconds between camera grabs from chat, globally
OVERRIDE_SECONDS = 45.0    # how long a viewer holds the camera

MAX_MESSAGE_LEN = 460      # Twitch caps at 500; leave room for the envelope

# Commands that wait on the game run in a bounded pool. Unbounded, a raid where
# 500 viewers type !stats at once spawns 500 threads, each parked for up to
# three seconds, and the replies overflow the IRC rate-limit window anyway.
SLOW_COMMAND_WORKERS = 4
SLOW_COMMAND_QUEUE = 32


def _load_config():
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception as e:
            logging.error(f"Twitch: could not read {CONFIG_PATH}: {e}")
    cfg["nick"] = os.environ.get("TWITCH_NICK", cfg.get("nick", ""))
    cfg["token"] = os.environ.get("TWITCH_TOKEN", cfg.get("token", ""))
    cfg["channel"] = os.environ.get("TWITCH_CHANNEL", cfg.get("channel", ""))
    return cfg


class ClaimRegistry:
    """Maps a Twitch login to the dwarf they have claimed.

    The claim also lands in-game as the unit's nickname, so it survives a bot
    restart even if this file is lost; the file just makes lookups cheap and
    keeps a viewer from claiming a second dwarf.
    """

    def __init__(self, path=CLAIMS_PATH):
        self.path = path
        self.lock = threading.Lock()
        self.by_user = {}
        self._load()

    def _load(self):
        if not os.path.exists(self.path):
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                self.by_user = json.load(f)
        except Exception as e:
            logging.error(f"Twitch: could not read claims: {e}")
            self.by_user = {}

    def _save(self):
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.by_user, f, indent=2)
            os.replace(tmp, self.path)
        except Exception as e:
            logging.error(f"Twitch: could not save claims: {e}")

    def get(self, user):
        with self.lock:
            return self.by_user.get(user.lower())

    def set(self, user, unit_id, dwarf_name):
        # A non-integer id (a serialisation slip upstream sending null) would be
        # stored and then never match anything in owner_of, so the viewer would
        # silently lose their dwarf on the next restart. Refuse it here instead.
        try:
            unit_id = int(unit_id)
        except (TypeError, ValueError):
            logging.error(f"Twitch: refusing claim for {user}: bad unit id {unit_id!r}")
            return False
        with self.lock:
            self.by_user[user.lower()] = {"unit_id": unit_id, "name": dwarf_name, "ts": time.time()}
            self._save()
        return True

    def release(self, user):
        """Give up a claim. Returns the record that was released, or None."""
        with self.lock:
            rec = self.by_user.pop(user.lower(), None)
            if rec is not None:
                self._save()
            return rec

    def count(self):
        with self.lock:
            return len(self.by_user)

    def owner_of(self, unit_id):
        with self.lock:
            for user, rec in self.by_user.items():
                if rec.get("unit_id") == unit_id:
                    return user
        return None


class Poll:
    def __init__(self, question, options, duration=60.0):
        self.question = question
        self.options = options
        self.votes = {}          # voter -> option index
        self.opened = time.time()
        self.duration = duration

    @property
    def expired(self):
        return time.time() - self.opened > self.duration

    def vote(self, user, index):
        if 0 <= index < len(self.options):
            self.votes[user.lower()] = index
            return True
        return False

    def tally(self):
        counts = [0] * len(self.options)
        for idx in self.votes.values():
            counts[idx] += 1
        return counts

    def result_line(self):
        counts = self.tally()
        total = sum(counts) or 1
        parts = [
            f"{self.options[i]} {counts[i]} ({100 * counts[i] // total}%)"
            for i in range(len(self.options))
        ]
        winner = max(range(len(counts)), key=lambda i: counts[i])
        return f"POLL CLOSED - {self.question} | " + " | ".join(parts) + f" | WINNER: {self.options[winner]}"


class TwitchBridge:
    """Connects Twitch chat to the Antfarm engine."""

    def __init__(self, client, engine, config=None):
        self.client = client
        self.engine = engine
        self.cfg = config or _load_config()
        # The OAuth token is pulled out of the config dict and kept apart from
        # it. Anything that logs or reprs self.cfg -- a plugin, a debug line --
        # would otherwise put a live chat credential in antfarm.log.
        self._token = self.cfg.pop("token", "") or ""
        self.claims = ClaimRegistry()

        self.sock = None
        self.running = False
        self.thread = None
        self.connected = False

        self._send_times = []
        self._send_lock = threading.Lock()
        self._user_last_cmd = {}
        self._last_camera_grab = 0.0

        self.poll = None
        self.poll_lock = threading.Lock()
        self._last_auto_poll = 0.0
        self._slow_pool = None
        self._slow_queued = 0
        self._slow_lock = threading.Lock()
        self._watchdog = None

        self.commands = {
            "!help": self.cmd_help,
            "!commands": self.cmd_help,
            "!next": self.cmd_next,
            "!focus": self.cmd_focus,
            "!stats": self.cmd_stats,
            "!skills": self.cmd_skills,
            "!health": self.cmd_health,
            "!kills": self.cmd_kills,
            "!name": self.cmd_name,
            "!claim": self.cmd_name,
            "!mine": self.cmd_mine,
            "!unclaim": self.cmd_unclaim,
            "!release": self.cmd_unclaim,
            "!who": self.cmd_who,
            "!fort": self.cmd_fort,
            "!build": self.cmd_build,
            "!vote": self.cmd_vote,
            "!poll": self.cmd_poll,
            "!director": self.cmd_director,
        }

    # ------------------------------------------------------------------ #
    # lifecycle                                                          #
    # ------------------------------------------------------------------ #

    def configured(self):
        return bool(self.cfg.get("nick") and self._token and self.cfg.get("channel"))

    def start(self):
        if not self.configured():
            logging.warning(
                "Twitch bridge not started: set TWITCH_NICK, TWITCH_TOKEN and "
                "TWITCH_CHANNEL (or fill in config/twitch.json)."
            )
            return False
        if self.running:
            return True
        self.running = True
        self._slow_pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=SLOW_COMMAND_WORKERS, thread_name_prefix="antfarm-chat")
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

        # Big fortress moments become chat prompts.
        self.engine.event_bus.subscribe("*", self._on_game_event)
        self._watchdog = threading.Thread(target=self._poll_watchdog, daemon=True)
        self._watchdog.start()
        return True

    def stop(self):
        self.running = False
        try:
            self.engine.event_bus.unsubscribe("*", self._on_game_event)
        except Exception:
            pass
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        pool, self._slow_pool = self._slow_pool, None
        if pool:
            # Do not wait: a probe in flight blocks for up to three seconds and
            # the caller is usually shutting the dashboard down.
            pool.shutdown(wait=False)
        # The watchdog checks self.running at the top of a 2s sleep, so joining
        # it makes teardown deterministic instead of leaving a thread running
        # for another two seconds after stop() returns.
        wd, self._watchdog = self._watchdog, None
        if wd and wd.is_alive():
            wd.join(timeout=2.5)

    @property
    def channel(self):
        ch = self.cfg.get("channel", "").lstrip("#").lower()
        return f"#{ch}"

    def _run(self):
        backoff = 2.0
        while self.running:
            try:
                self._connect()
                backoff = 2.0
                self._read_loop()
            except Exception as e:
                logging.error(f"Twitch: connection error: {e}")
            finally:
                self.connected = False
                try:
                    if self.sock:
                        self.sock.close()
                except Exception:
                    pass
                self.sock = None

            if self.running:
                logging.info(f"Twitch: reconnecting in {backoff:.0f}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, 60.0)

    def _connect(self):
        ctx = ssl.create_default_context()
        raw = socket.create_connection((IRC_HOST, IRC_PORT), timeout=30)
        self.sock = ctx.wrap_socket(raw, server_hostname=IRC_HOST)
        self.sock.settimeout(340)  # Twitch PINGs every ~5 min

        self._raw(f"PASS {self._token}")
        self._raw(f"NICK {self.cfg['nick'].lower()}")
        # Tags give us the badges we need to tell a moderator from a viewer.
        self._raw("CAP REQ :twitch.tv/tags twitch.tv/commands")
        self._raw(f"JOIN {self.channel}")
        self.connected = True
        logging.info(f"Twitch: connected to {self.channel} as {self.cfg['nick']}")

    def _raw(self, line):
        if not self.sock:
            return
        self.sock.sendall((line + "\r\n").encode("utf-8"))

    def _read_loop(self):
        buffer = ""
        while self.running and self.sock:
            data = self.sock.recv(8192)
            if not data:
                raise ConnectionError("Twitch closed the connection")
            buffer += data.decode("utf-8", errors="replace")
            while "\r\n" in buffer:
                line, buffer = buffer.split("\r\n", 1)
                self._handle_line(line)

    # ------------------------------------------------------------------ #
    # IRC plumbing                                                       #
    # ------------------------------------------------------------------ #

    # Commands that wait on a round-trip to the game.
    SLOW_COMMANDS = frozenset({"!stats", "!skills", "!health", "!kills"})

    # Moderator/broadcaster only. Listed here so the dispatcher can reject them
    # before charging the caller's cooldown.
    PRIVILEGED = frozenset({"!poll", "!director"})

    _PRIVMSG = re.compile(r"^(?:@(?P<tags>\S*) )?:(?P<user>[^!]+)![^ ]+ PRIVMSG (?P<chan>#\S+) :(?P<msg>.*)$")

    def _handle_line(self, line):
        if not line:
            return
        if line.startswith("PING"):
            with self._send_lock:
                self._raw("PONG :tmi.twitch.tv")
            return

        m = self._PRIVMSG.match(line)
        if not m:
            return

        user = m.group("user")
        msg = m.group("msg").strip()
        tags = self._parse_tags(m.group("tags"))

        if not msg.startswith("!"):
            return

        parts = msg.split(None, 1)
        verb = parts[0].lower()
        rest = parts[1].strip() if len(parts) > 1 else ""

        handler = self.commands.get(verb)
        if not handler:
            return

        # Moderator-only commands are checked before the cooldown is charged.
        # A viewer typing !director got no reply and lost their eight-second
        # slot to a command that was never going to do anything.
        if verb in self.PRIVILEGED and not self._is_privileged(tags):
            return

        # !vote is deliberately exempt from the cooldown: a poll is short and
        # rate-limiting it would silently drop most of the votes.
        if verb != "!vote" and not self._cooldown_ok(user):
            return

        def run():
            try:
                handler(user, rest, tags)
            except Exception as e:
                logging.error(f"Twitch: handler {verb} failed: {e}")

        if verb in self.SLOW_COMMANDS:
            # These wait on the game to answer a probe (up to 3s). Running them
            # inline would stop the bot reading chat -- and delay its PONG --
            # for that whole time, per command.
            self._submit_slow(verb, run)
        else:
            run()

    def _submit_slow(self, verb, fn):
        """Queue a game round-trip on the bounded pool.

        Shedding load is the right failure here: during a raid the replies would
        be dropped by the rate limiter anyway, so queueing thousands of probes
        only burns threads and delays the ones that will be answered.
        """
        pool = self._slow_pool
        if pool is None:
            fn()
            return
        with self._slow_lock:
            if self._slow_queued >= SLOW_COMMAND_QUEUE:
                logging.warning(f"Twitch: dropping {verb}, slow-command queue is full")
                return
            self._slow_queued += 1

        def wrapped():
            try:
                fn()
            finally:
                with self._slow_lock:
                    self._slow_queued -= 1

        try:
            pool.submit(wrapped)
        except RuntimeError:
            # Pool already shut down (the bridge is stopping).
            with self._slow_lock:
                self._slow_queued -= 1

    @staticmethod
    def _parse_tags(raw):
        tags = {}
        if not raw:
            return tags
        for pair in raw.split(";"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                tags[k] = v
        return tags

    @staticmethod
    def _is_privileged(tags):
        badges = tags.get("badges", "")
        return (
            tags.get("mod") == "1"
            or "broadcaster/1" in badges
            or "moderator/1" in badges
        )

    def _cooldown_ok(self, user):
        now = time.time()
        last = self._user_last_cmd.get(user.lower(), 0)
        if now - last < USER_COOLDOWN:
            return False
        self._user_last_cmd[user.lower()] = now
        return True

    def say(self, text):
        """Send to chat, dropping messages that would trip Twitch's rate limit."""
        if not self.connected or not self.sock:
            return False
        text = text.replace("\r", " ").replace("\n", " ")[:MAX_MESSAGE_LEN]
        # The write stays inside the lock. Three threads reach this -- the IRC
        # read loop, the poll watchdog, and the DFClient listener via
        # _on_game_event -- and an ssl.SSLSocket is not safe for concurrent
        # sendall: you get an SSLError or two interleaved IRC lines.
        with self._send_lock:
            now = time.time()
            self._send_times = [t for t in self._send_times if now - t < RATE_LIMIT_WINDOW]
            if len(self._send_times) >= RATE_LIMIT_MESSAGES:
                logging.warning("Twitch: rate limit reached, dropping message")
                return False
            self._send_times.append(now)
            try:
                self._raw(f"PRIVMSG {self.channel} :{text}")
                return True
            except Exception as e:
                logging.error(f"Twitch: send failed: {e}")
                return False

    # ------------------------------------------------------------------ #
    # game data helpers                                                  #
    # ------------------------------------------------------------------ #

    def _state(self):
        return self.client.latest_state or {}

    def _focused(self):
        return self._state().get("unit_data")

    def _resolve(self, user, query):
        """Pick the dwarf a command is about.

        With an argument, look it up by nickname or name. Without one, prefer
        the viewer's own claimed dwarf, then whoever the camera is on.
        """
        if query:
            return self.engine.find_citizen(query)
        claim = self.claims.get(user)
        if claim:
            found = self.engine.find_citizen(claim.get("name") or "")
            if found:
                return found
        return self._focused()

    def _probe(self, unit_id, timeout=3.0):
        """Fetch one full profile out-of-band from the Lua server.

        The server answers several probes at once and publishes them as a list.
        It used to hold a single probe id, so two viewers typing !stats within
        three seconds of each other overwrote one another's request and at most
        one of them ever got a reply.
        """
        if unit_id is None:
            return None
        self.client.probe_unit(unit_id)
        deadline = time.time() + timeout
        while time.time() < deadline:
            state = self._state()
            for data in state.get("probes") or []:
                if data and data.get("id") == unit_id:
                    return data
            # Older servers publish one profile at a time.
            data = state.get("probe_data")
            if data and data.get("id") == unit_id:
                return data
            focused = state.get("unit_data")
            if focused and focused.get("id") == unit_id:
                return focused
            time.sleep(0.15)
        return None

    @staticmethod
    def _stress_word(stress):
        if stress > 50000:
            return "miserable"
        if stress > 10000:
            return "stressed"
        if stress > 0:
            return "content"
        return "ecstatic"

    @staticmethod
    def _find_in(candidates, query):
        """find_citizen's matching order, restricted to a given list."""
        q = (query or "").strip().lower()
        if not q:
            return None
        for field in ("nick", "name"):
            for d in candidates:
                if (d.get(field) or "").lower() == q:
                    return d
        for field in ("nick", "name"):
            for d in candidates:
                if q in (d.get(field) or "").lower():
                    return d
        return None

    @staticmethod
    def _label(d):
        nick = (d.get("nick") or "").strip()
        name = d.get("name", "a dwarf")
        return f"{name} ({nick})" if nick else name

    # ------------------------------------------------------------------ #
    # commands                                                           #
    # ------------------------------------------------------------------ #

    def cmd_help(self, user, rest, tags):
        self.say(
            "Antfarm commands: !next (next dwarf) | !focus <name> | !stats [name] | "
            "!skills [name] | !health [name] | !kills [name] | !name (claim a dwarf) | "
            "!unclaim | !mine | !who | !fort | !build | !vote <n>"
        )

    def cmd_next(self, user, rest, tags):
        now = time.time()
        if now - self._last_camera_grab < CAMERA_COOLDOWN and not self._is_privileged(tags):
            remaining = int(CAMERA_COOLDOWN - (now - self._last_camera_grab))
            self.say(f"@{user} the camera is settling, {remaining}s to go.")
            return
        target = self.engine.next_citizen(owner=user)
        if not target:
            self.say(f"@{user} no citizens in view yet.")
            return
        self._last_camera_grab = now
        self.say(f"@{user} panned to {self._label(target)} - {target.get('current_job', 'Idle')}")

    def cmd_focus(self, user, rest, tags):
        if not rest:
            self.say(f"@{user} usage: !focus <dwarf name>")
            return
        now = time.time()
        if now - self._last_camera_grab < CAMERA_COOLDOWN and not self._is_privileged(tags):
            remaining = int(CAMERA_COOLDOWN - (now - self._last_camera_grab))
            self.say(f"@{user} the camera is settling, {remaining}s to go.")
            return
        target = self.engine.find_citizen(rest)
        if not target:
            self.say(f"@{user} no citizen matching '{rest}'.")
            return
        self._last_camera_grab = now
        self.engine.viewer_focus(target.get("id"), owner=user, duration=OVERRIDE_SECONDS)
        self.say(
            f"@{user} camera locked on {self._label(target)} for {int(OVERRIDE_SECONDS)}s - "
            f"{target.get('current_job', 'Idle')}, {self._stress_word(target.get('stress', 0))}"
        )

    def cmd_stats(self, user, rest, tags):
        d = self._resolve(user, rest)
        if not d:
            self.say(f"@{user} no dwarf to report on yet.")
            return
        full = self._probe(d.get("id")) or d
        health = full.get("health") or {}
        self.say(
            f"{self._label(full)} - {full.get('profession', 'Peasant')}, "
            f"age {full.get('age', '?')}, currently {full.get('current_job', 'Idle')}. "
            f"Mood: {self._stress_word(full.get('stress', 0))} ({full.get('stress', 0)}). "
            f"Health: {health.get('status', 'unknown')}."
        )

    def cmd_skills(self, user, rest, tags):
        d = self._resolve(user, rest)
        if not d:
            self.say(f"@{user} no dwarf to report on yet.")
            return
        full = self._probe(d.get("id"))
        skills = (full or {}).get("skills") or []
        if not skills:
            self.say(f"{self._label(d)} has no notable training yet.")
            return
        listed = ", ".join(f"{s.get('name')} {s.get('rating')}" for s in skills[:5])
        self.say(f"{self._label(d)} top skills: {listed}")

    def cmd_health(self, user, rest, tags):
        d = self._resolve(user, rest)
        if not d:
            self.say(f"@{user} no dwarf to report on yet.")
            return
        full = self._probe(d.get("id"))
        h = (full or {}).get("health") or {}
        self.say(
            f"{self._label(d)}: {h.get('status', 'unknown')}, "
            f"{h.get('wounds', 0)} wound(s), blood {h.get('blood_pct', 100)}%."
        )

    def cmd_kills(self, user, rest, tags):
        d = self._resolve(user, rest)
        if not d:
            self.say(f"@{user} no dwarf to report on yet.")
            return
        full = self._probe(d.get("id"))
        k = (full or {}).get("kills") or {}
        total = k.get("total", 0)
        if not total:
            self.say(f"{self._label(d)} has never killed anything. Yet.")
            return
        notable = ", ".join(f"{n.get('count')}x {n.get('name')}" for n in (k.get("notable") or []))
        self.say(f"{self._label(d)} has {total} kill(s): {notable}")

    def cmd_name(self, user, rest, tags):
        existing = self.claims.get(user)
        if existing:
            self.say(f"@{user} you already own {existing.get('name')}. One dwarf per viewer.")
            return

        pool = self.engine.unclaimed_citizens()
        if not pool:
            self.say(f"@{user} every citizen is claimed. Wait for the next migrant wave!")
            return

        # A requested name wins if it is genuinely unclaimed; otherwise roll.
        #
        # Resolve against the unclaimed pool rather than the whole roster:
        # find_citizen matches nicknames before names, and a nickname IS a
        # previous claimant's login, so "!name Urist" would otherwise match
        # claimed dwarf nicknamed "uristfan" and refuse the free Urist standing
        # right there. Compare by id -- roster records are rebuilt five times a
        # second, so dict equality between two reads is not reliable.
        target = None
        if rest:
            pool_ids = {d.get("id") for d in pool}
            candidate = self._find_in(pool, rest) or self.engine.find_citizen(rest)
            if candidate and candidate.get("id") in pool_ids:
                target = next(d for d in pool if d.get("id") == candidate.get("id"))
            elif candidate:
                self.say(f"@{user} {self._label(candidate)} is already claimed.")
                return
            else:
                self.say(f"@{user} no citizen matching '{rest}'.")
                return
        if target is None:
            target = random.choice(pool)

        nickname = user[:32]
        if not self.claims.set(user, target.get("id"), target.get("name")):
            self.say(f"@{user} something went wrong claiming that dwarf; try again.")
            return
        self.client.set_nickname(target.get("id"), nickname)
        self.say(
            f"@{user} you are now {target.get('name')} the "
            f"{target.get('profession', 'Peasant')}. Try !stats, !health, !kills."
        )

    def cmd_mine(self, user, rest, tags):
        claim = self.claims.get(user)
        if not claim:
            self.say(f"@{user} you have not claimed a dwarf. Type !name to get one.")
            return
        d = self.engine.find_citizen(claim.get("name") or "")
        if not d:
            self.say(f"@{user} {claim.get('name')} is no longer among the living. Sorry.")
            return
        self.say(
            f"@{user} {self._label(d)} - {d.get('profession', 'Peasant')}, "
            f"{d.get('current_job', 'Idle')}, {self._stress_word(d.get('stress', 0))}"
        )

    def cmd_unclaim(self, user, rest, tags):
        """Give up a claim.

        Without this a viewer whose dwarf died was blocked from ever claiming
        another one: the claim file kept the dead dwarf forever and the only way
        out was to edit it by hand and restart.
        """
        rec = self.claims.release(user)
        if not rec:
            self.say(f"@{user} you have not claimed a dwarf. Type !name to get one.")
            return
        # Clear the in-game nickname too -- it is the other half of the claim,
        # and leaving it set means the dwarf still reads as claimed to !name.
        unit_id = rec.get("unit_id")
        if unit_id is not None:
            self.client.set_nickname(unit_id, "")
        self.say(f"@{user} you have released {rec.get('name')}. Type !name for another.")

    def cmd_who(self, user, rest, tags):
        d = self._focused()
        if not d:
            self.say("The camera is not on anyone right now.")
            return
        owner = self.claims.owner_of(d.get("id"))
        suffix = f" - claimed by @{owner}" if owner else " - unclaimed, type !name"
        self.say(f"Now watching {self._label(d)}, {d.get('current_job', 'Idle')}{suffix}")

    def cmd_fort(self, user, rest, tags):
        stats = self._state().get("fortress_stats") or {}
        if not self._state().get("map_loaded"):
            self.say("The fortress is not loaded yet.")
            return
        self.say(
            f"Fortress: {stats.get('pop', 0)} citizens | "
            f"Year {stats.get('year', 0)}, {stats.get('season', 'Spring')} | "
            f"{stats.get('fps', 0)} FPS | {self.claims.count()} dwarves claimed"
        )

    def cmd_build(self, user, rest, tags):
        build = self._state().get("build")
        if not build:
            self.say("No build plan is running.")
            return
        if not build.get("anchored"):
            self.say("The fortress site has not been chosen yet.")
            return
        state = "ready to start" if build.get("ready") else build.get("status", "working")
        auto = " (auto)" if build.get("auto") else ""
        self.say(
            f"Building {build.get('label')} - step {build.get('step')} of "
            f"{build.get('total')}{auto}: {build.get('note')}. Currently {state}."
        )

    def cmd_director(self, user, rest, tags):
        if not self._is_privileged(tags):
            return
        mode = (rest or "director").strip().lower()
        if mode not in ("director", "timed", "event", "idle"):
            self.say("Modes: director, timed, event, idle")
            return
        self.engine.clear_override()
        self.engine.set_mode(mode)
        self.say(f"Camera mode set to {mode}.")

    # ------------------------------------------------------------------ #
    # polls                                                              #
    # ------------------------------------------------------------------ #

    def cmd_poll(self, user, rest, tags):
        if not self._is_privileged(tags):
            return
        if "|" not in rest:
            self.say("Usage: !poll Question? | option one | option two")
            return
        bits = [b.strip() for b in rest.split("|") if b.strip()]
        if len(bits) < 3:
            self.say("A poll needs a question and at least two options.")
            return
        self.open_poll(bits[0], bits[1:])

    def open_poll(self, question, options, duration=60.0):
        with self.poll_lock:
            if self.poll and not self.poll.expired:
                return False
            self.poll = Poll(question, options, duration)
        listed = " | ".join(f"{i + 1}) {o}" for i, o in enumerate(options))
        self.say(f"POLL ({int(duration)}s): {question} -- {listed} -- vote with !vote <number>")
        return True

    def cmd_vote(self, user, rest, tags):
        with self.poll_lock:
            poll = self.poll
        if not poll or poll.expired:
            return
        try:
            idx = int(rest.strip()) - 1
        except (ValueError, AttributeError):
            return
        poll.vote(user, idx)

    def _poll_watchdog(self):
        while self.running:
            time.sleep(2.0)
            with self.poll_lock:
                poll = self.poll
                if poll and poll.expired:
                    self.poll = None
                else:
                    poll = None
            if poll and poll.votes:
                self.say(poll.result_line())

    # ------------------------------------------------------------------ #
    # game events -> chat                                                #
    # ------------------------------------------------------------------ #

    # Only genuinely dramatic events are worth interrupting chat for; job
    # start/finish fire constantly and would drown everything else out.
    # CitizenDeparted is deliberately absent: a dwarf leaving the roster is
    # often a banishment, a visitor going home or a squad off the map edge, and
    # announcing those as deaths was a steady source of false alarms.
    _ANNOUNCE = {
        "CitizenDeath": "{name} has died!",
        "CitizenEnteredCombat": "{name} is in combat!",
    }

    def _on_game_event(self, event):
        if not self.connected:
            return
        template = self._ANNOUNCE.get(event.name)
        if not template:
            return

        name = event.payload.get("name") or "A dwarf"
        owner = self.claims.owner_of(event.payload.get("id"))
        line = template.format(name=name)
        if owner:
            line = f"@{owner} {line}"
        self.say(line)

        # A death is the moment the audience most wants a say in what happens.
        if event.name == "CitizenDeath" and time.time() - self._last_auto_poll > 300:
            self._last_auto_poll = time.time()
            self.open_poll(
                f"{name} is dead. What now?",
                ["Build a memorial slab", "Carry on, no time to mourn", "Throw a party"],
                duration=90.0,
            )


def main():
    """Run the bridge on its own, against a fortress that is already up."""
    logging.basicConfig(
        filename="antfarm.log", level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )
    from antfarm.client import DFClient
    from antfarm.engine import AntfarmEngine

    client = DFClient()
    engine = AntfarmEngine(client)
    client.connect()
    engine.start()

    bridge = TwitchBridge(client, engine)
    if not bridge.configured():
        print("Twitch is not configured.")
        print("Set TWITCH_NICK, TWITCH_TOKEN and TWITCH_CHANNEL, or write config/twitch.json:")
        print('  {"nick": "mybot", "token": "oauth:xxxx", "channel": "mychannel"}')
        return 1

    bridge.start()
    print(f"Antfarm Twitch bridge running on #{bridge.cfg['channel'].lstrip('#')}. Ctrl-C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop()
        engine.stop()
        client.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
