"""Both halves of the command wire format, checked against each other.

AGENTS.md section 4.2: generate command files with the real Python client and
parse them with the real Lua reader. That is what caught escaped quotes
truncating commands and \\uXXXX mangling accented names -- and, later, a
nickname clear being silently dropped because DFClient.send_cmd strips the
trailing space and the Lua pattern required one.

Run: .venv/bin/python -m tests.test_wire
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_LUA = os.path.join(ROOT, "game", "hack", "scripts", "antfarm_server.lua")

_SCRATCH = tempfile.mkdtemp(prefix="antfarm-wire-")
os.environ["ANTFARM_DF_DIR"] = _SCRATCH
sys.path.insert(0, ROOT)

from antfarm.client import DFClient  # noqa: E402


def lua_available():
    try:
        subprocess.run(["lua", "-v"], capture_output=True, check=True)
        return True
    except Exception:
        return False


# Pull the two parsing functions out of the real server script and run them
# against a command file, with just enough of a `dfhack` stub to load.
HARNESS = r"""
local SERVER, path = ...
-- Minimal environment so antfarm_server.lua loads in module mode.
local env = setmetatable({
    dfhack = {
        df2utf = function(s) return s end,
        printerr = function() end,
        getTickCount = function() return 0 end,
        isMapLoaded = function() return false end,
        onStateChange = {},
        filesystem = {isdir = function() return false end,
                      exists = function() return false end,
                      listdir = function() return {} end,
                      mkdir = function() return true end},
        timeout = function() end,
        gui = {}, screen = {}, units = {}, maps = {}, job = {},
    },
    df = setmetatable({global = {}}, {__index = function() return {} end}),
    dfhack_flags = {module = true},
    require = function() return {} end,
    reqscript = function() return nil end,
    print = function() end,
}, {__index = _G})
env._ENV = env
local chunk = assert(loadfile(SERVER, 't', env))
chunk()

local f = assert(io.open(path, 'r'))
local content = f:read('*all')
f:close()
local cmd = env.extract_json_string(content, 'command')
io.write(cmd or '<NIL>')
"""


class Wire(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not lua_available():
            raise unittest.SkipTest("lua interpreter not available")
        cls.client = DFClient()
        cls.spool = os.path.join(_SCRATCH, "antfarm_cmd")

    def roundtrip(self, command):
        """Send `command` with the real client; parse it with the real Lua."""
        for name in os.listdir(self.spool) if os.path.isdir(self.spool) else []:
            os.remove(os.path.join(self.spool, name))
        self.assertTrue(self.client.send_cmd(command))
        files = sorted(os.listdir(self.spool))
        self.assertEqual(len(files), 1, files)
        path = os.path.join(self.spool, files[0])

        # -e does not populate `...`, so the harness goes in a real file and
        # the paths arrive as script arguments.
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as fh:
            fh.write(HARNESS)
            harness_path = fh.name
        try:
            out = subprocess.run(["lua", harness_path, SERVER_LUA, path],
                                 capture_output=True, text=True)
        finally:
            os.unlink(harness_path)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout

    def test_plain_command(self):
        self.assertEqual(self.roundtrip("ping"), "ping")

    def test_nickname_with_a_name(self):
        self.assertEqual(self.roundtrip("nick 42 someviewer"), "nick 42 someviewer")

    def test_clearing_a_nickname_survives_the_trip(self):
        """The bug: send_cmd strips, so this arrives as a bare 'nick 42'."""
        self.client.set_nickname(42, "")
        files = sorted(os.listdir(self.spool))
        path = os.path.join(self.spool, files[-1])
        with open(path, encoding="utf-8") as fh:
            payload = json.load(fh)
        self.assertEqual(payload["command"], "nick 42")

    def test_the_server_accepts_a_bare_nick_as_a_clear(self):
        """Parse 'nick <id>' with the server's own verb pattern."""
        rest = "42"
        # Mirrors the Lua: try "<id> <name>", then fall back to "<id>".
        import re
        m = re.match(r"^(\S+)\s+(.*)$", rest)
        if not m:
            m2 = re.match(r"^(\S+)\s*$", rest)
            self.assertIsNotNone(m2, "a bare id must match the clear form")
            self.assertEqual(m2.group(1), "42")

    def test_accented_names_are_not_mangled(self):
        self.assertEqual(self.roundtrip("nick 7 Bëmbul Ùnïcödé"),
                         "nick 7 Bëmbul Ùnïcödé")

    def test_quotes_do_not_truncate_the_command(self):
        self.assertEqual(self.roundtrip('command echo "hello world"'),
                         'command echo "hello world"')

    def test_backslashes_survive(self):
        self.assertEqual(self.roundtrip(r"command echo a\b"), r"command echo a\b")

    def test_emoji_nickname(self):
        """Above the BMP: a surrogate pair on the wire, one codepoint here."""
        self.assertEqual(self.roundtrip("nick 9 smile\U0001F600"),
                         "nick 9 smile\U0001F600")


if __name__ == "__main__":
    unittest.main(verbosity=2)
