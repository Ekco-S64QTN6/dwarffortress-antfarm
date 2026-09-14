import os
import socket
import json
import time
import itertools
import threading
import logging

class DFClient:
    def __init__(self, host="127.0.0.1", port=5080):
        self.host = host
        self.port = port
        self.connected = False
        self.lock = threading.Lock()
        self.listener_thread = None
        self.sock = None
        self.use_file_fallback = False
        
        # State file locations.
        # ANTFARM_DF_DIR points the client at a specific Dwarf Fortress
        # directory. It lets the test suites run against a scratch directory
        # instead of the real game -- without it, running tests while a fort is
        # live has the two fighting over the same state file, and test commands
        # (nicknames, camera moves) are executed by the running fortress.
        df_dir = os.environ.get("ANTFARM_DF_DIR")
        if df_dir:
            self.state_file_paths = [os.path.join(df_dir, "antfarm_state.json")]
        else:
            self.state_file_paths = [
                "game/antfarm_state.json",
                "antfarm_state.json"
            ]
        # The Lua server drains a spool directory: one command per file, written
        # tmp-then-rename so it is never read half-written. A single shared
        # command file cannot work -- the heartbeat alone overwrites a queued
        # command within 200ms, and chat can burst a dozen at once.
        if df_dir:
            self.cmd_dir_paths = [os.path.join(df_dir, "antfarm_cmd")]
        else:
            self.cmd_dir_paths = [
                "game/antfarm_cmd",
                "antfarm_cmd"
            ]
        self._cmd_seq = itertools.count(1)
        self._last_socket_attempt = 0.0
        self.socket_retry_interval = 15.0
        self._logged_socket_fallback = False
        
        # Latest data from the game
        self.latest_state = None
        self.citizens_list = []
        
        # Callbacks for new data
        self.on_state_update_callbacks = []
        self.on_citizens_update_callbacks = []
        
    def add_state_callback(self, cb):
        self.on_state_update_callbacks.append(cb)
        
    def add_citizens_callback(self, cb):
        self.on_citizens_update_callbacks.append(cb)
        
    def connect(self):
        self.connected = True
        logging.info(f"Initializing Antfarm IPC client (Socket {self.host}:{self.port} + File Fallback)")
        
        # Start listener loop
        self.listener_thread = threading.Thread(target=self._listen, daemon=True)
        self.listener_thread.start()
        
    def _get_active_state_path(self):
        for p in self.state_file_paths:
            if os.path.exists(p):
                return p
        return self.state_file_paths[0]

    def _get_active_cmd_dir(self):
        for d in self.cmd_dir_paths:
            parent = os.path.dirname(d)
            if not parent or os.path.exists(parent):
                return d
        return self.cmd_dir_paths[0]

    def _listen(self):
        buffer = ""
        last_file_mtime = 0
        last_read_error_log = 0.0
        
        while self.connected:
            # 1. Try TCP Socket Transport.
            # File IPC is the supported default (see AGENTS.md 6.1.7 -- the
            # luasocket accept() path has a history of segfaulting DF), but if a
            # socket server is running we prefer it, and we keep retrying on a
            # slow timer rather than latching to files forever.
            if self.use_file_fallback and (time.time() - self._last_socket_attempt) > self.socket_retry_interval:
                self.use_file_fallback = False

            if not self.use_file_fallback and not self.sock:
                self._last_socket_attempt = time.time()
                s = None
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.settimeout(1.0)
                    s.connect((self.host, self.port))
                    s.settimeout(None)
                    with self.lock:
                        self.sock = s
                    s = None  # handed over; do not close it below
                    logging.info(f"Connected to Antfarm TCP Socket Server on {self.host}:{self.port}")
                except Exception:
                    # Socket unavailable -> activate File-based IPC fallback.
                    # Logged once: the retry fires every 15s and would otherwise
                    # add ~240 identical lines an hour to a streaming session.
                    if not self._logged_socket_fallback:
                        self._logged_socket_fallback = True
                        logging.info("TCP socket unavailable; using file-based IPC (antfarm_state.json).")
                    self.use_file_fallback = True
                finally:
                    # A failed connect leaves the socket open until the garbage
                    # collector gets to it. At one retry every 15 seconds that
                    # is a slow file-descriptor leak over a long stream.
                    if s is not None:
                        try:
                            s.close()
                        except Exception:
                            pass

            if self.sock and not self.use_file_fallback:
                try:
                    data = self.sock.recv(65536).decode("utf-8", errors="replace")
                    if not data:
                        logging.warning("Socket closed by server. Falling back to File IPC...")
                        with self.lock:
                            if self.sock:
                                self.sock.close()
                                self.sock = None
                        self.use_file_fallback = True
                        buffer = ""
                        continue
                        
                    buffer += data
                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        if line.strip():
                            self._process_state_json(line)
                except Exception as e:
                    logging.info(f"Socket receive error: {e}; switching to file IPC.")
                    with self.lock:
                        if self.sock:
                            try:
                                self.sock.close()
                            except:
                                pass
                            self.sock = None
                    self.use_file_fallback = True
                    buffer = ""
                    
            # 2. File-based IPC Fallback Loop
            if self.use_file_fallback:
                state_path = self._get_active_state_path()
                if os.path.exists(state_path):
                    try:
                        mtime = os.path.getmtime(state_path)
                        if mtime > last_file_mtime:
                            last_file_mtime = mtime
                            with open(state_path, "r", encoding="utf-8", errors="replace") as f:
                                content = f.read()
                            if content.strip():
                                self._process_state_json(content)
                    except Exception as e:
                        # Rate-limited error, not debug: if the state file is
                        # persistently unreadable the dashboard otherwise sits on
                        # "WAITING FOR GAME SAVE TO LOAD" forever with no clue why.
                        now = time.time()
                        if now - last_read_error_log > 10.0:
                            last_read_error_log = now
                            logging.error(f"Cannot read state file {state_path}: {e}")
                        
                time.sleep(0.2) # poll file every 200ms
                
    def _process_state_json(self, json_str):
        try:
            payload = json.loads(json_str)
            
            citizens = payload.get("citizens") or []
            if not isinstance(citizens, list):
                # A JSON encoder that renders an empty list as {} would other-
                # wise have every consumer iterating dict keys as if they were
                # citizen records.
                citizens = []

            with self.lock:
                self.latest_state = payload
                self.citizens_list = citizens
                
            # Trigger state update callbacks
            for cb in self.on_state_update_callbacks:
                try:
                    cb(payload)
                except Exception as e:
                    logging.error(f"Error in state callback: {e}")
                    
            # Trigger citizens update callbacks
            for cb in self.on_citizens_update_callbacks:
                try:
                    cb(self.citizens_list)
                except Exception as e:
                    logging.error(f"Error in citizens callback: {e}")
        except Exception as e:
            logging.error(f"Error parsing state JSON: {e}")
            
    def send_cmd(self, cmd_string):
        cmd_clean = cmd_string.strip()
        
        # Try Socket send first if active
        if self.sock and not self.use_file_fallback:
            try:
                with self.lock:
                    if self.sock:
                        self.sock.sendall((cmd_clean + "\n").encode("utf-8"))
                        return True
            except Exception as e:
                logging.warning(f"Error sending command via socket: {e}. Falling back to File IPC.")
                self.use_file_fallback = True
                
        # File IPC: drop one uniquely-named file into the spool directory.
        # Names are zero-padded and monotonic so the Lua side, which sorts
        # lexically, drains them in the order they were sent.
        try:
            cmd_dir = self._get_active_cmd_dir()
            os.makedirs(cmd_dir, exist_ok=True)
            name = "%08d-%d.json" % (next(self._cmd_seq), os.getpid())
            final_path = os.path.join(cmd_dir, name)
            tmp_path = final_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as f:
                # ensure_ascii=False keeps dwarf names (Bëmbul, Ünïcödé) as real
                # UTF-8 instead of \uXXXX escapes, which the Lua reader would
                # have to decode and which broke !focus on accented names.
                f.write(json.dumps({"command": cmd_clean}, ensure_ascii=False))
            os.replace(tmp_path, final_path)
            return True
        except Exception as e:
            logging.error(f"Error writing command file: {e}")
            return False

    def focus_unit(self, unit_id):
        return self.send_cmd(f"focus {unit_id}")
        
    def unfocus(self):
        return self.send_cmd("unfocus")
        
    def execute_dfhack(self, dfhack_cmd):
        return self.send_cmd(f"command {dfhack_cmd}")
        
    def set_mode(self, mode):
        return self.send_cmd(f"mode {mode}")

    def unpause(self):
        return self.send_cmd("unpause")

    def build_command(self, subcommand="status"):
        """Drive the guided Dreamfort build (antfarm_blueprint)."""
        return self.send_cmd(f"build {subcommand}")

    def probe_unit(self, unit_id):
        """Ask the server for one full profile; it lands in state['probe_data']."""
        return self.send_cmd(f"probe {unit_id}")

    def set_nickname(self, unit_id, nickname):
        return self.send_cmd(f"nick {unit_id} {nickname}")

    def disconnect(self):
        self.connected = False
        with self.lock:
            if self.sock:
                try:
                    self.sock.close()
                except Exception:
                    pass
                self.sock = None
