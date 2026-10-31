"""Unit tests for the opt-in, read-only live-game smoke launcher."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "antfarm_live_smoke_runner", ROOT / "tools" / "live_smoke.py"
)
assert SPEC and SPEC.loader
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class LiveSmokeSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.df_dir = Path(self.temp.name) / "DF installation with spaces"
        self.save_dir = self.df_dir / "data" / "save" / "region_test"
        self.save_dir.mkdir(parents=True)
        (self.save_dir / "world.sav").write_text("disposable save marker\n")
        (self.save_dir / smoke.MARKER_NAME).write_text(
            smoke.MARKER_CONTENT, encoding="utf-8"
        )

        runner = self.df_dir / smoke.RUNNER_NAME
        runner.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "[ \"$1\" = antfarm_live_smoke ]\n"
            "[ \"$2\" ]\n"
            "[ \"$3\" = region_test ]\n"
            "printf 'called\\n' >> runner.calls\n"
            "printf 'format=%s\\nrun_id=%s\\nmap_loaded=true\\n"
            "orders_status=ok\\nquarters_status=ok\\n"
            "checklist_status=ok\\nloaded_save_matches=true\\n"
            "loaded_save_folder=%s\\n' "
            "'antfarm-live-smoke-v1' \"$2\" \"$3\" > "
            "antfarm_live_smoke_\"$2\".txt\n",
            encoding="utf-8",
        )
        runner.chmod(0o755)
        native_runner = self.df_dir / "hack" / "dfhack-run"
        native_runner.parent.mkdir(parents=True)
        native_runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        native_runner.chmod(0o755)
        script = self.df_dir / smoke.LUA_SCRIPT
        script.parent.mkdir(parents=True)
        script.write_text("-- fake test install\n", encoding="utf-8")

    def validate(self, *, disposable=True, loaded=True, region="region_test"):
        return smoke.validate_target(
            str(self.df_dir), region, disposable, loaded
        )

    def test_requires_both_explicit_confirmations(self):
        with self.assertRaises(smoke.SmokeError):
            self.validate(disposable=False)
        with self.assertRaises(smoke.SmokeError):
            self.validate(loaded=False)
        self.assertFalse((self.df_dir / "runner.calls").exists())

    def test_requires_the_exact_marker_inside_a_real_fort_save(self):
        marker = self.save_dir / smoke.MARKER_NAME
        marker.unlink()
        with self.assertRaisesRegex(smoke.SmokeError, "marker"):
            self.validate()
        self.assertFalse((self.df_dir / "runner.calls").exists())

        marker.write_text("this is not an acknowledgement\n", encoding="utf-8")
        with self.assertRaisesRegex(smoke.SmokeError, "must contain exactly"):
            self.validate()
        self.assertFalse((self.df_dir / "runner.calls").exists())

    def test_rejects_generated_worlds_and_unsafe_region_names(self):
        (self.save_dir / "world.sav").unlink()
        (self.save_dir / "world.dat").write_text("world only\n")
        with self.assertRaisesRegex(smoke.SmokeError, "world.sav is required"):
            self.validate()
        for region in ("../region_test", "/tmp", "current", "region/a"):
            with self.subTest(region=region):
                with self.assertRaises(smoke.SmokeError):
                    self.validate(region=region)
        self.assertFalse((self.df_dir / "runner.calls").exists())

    def test_requires_the_installed_lua_probe_and_executable_wrapper(self):
        script = self.df_dir / smoke.LUA_SCRIPT
        script.unlink()
        with self.assertRaisesRegex(smoke.SmokeError, "Lua script not installed"):
            self.validate()
        script.write_text("-- restored\n", encoding="utf-8")

        runner = self.df_dir / smoke.RUNNER_NAME
        runner.chmod(0o644)
        with self.assertRaisesRegex(smoke.SmokeError, "executable DFHack wrapper"):
            self.validate()
        self.assertFalse((self.df_dir / "runner.calls").exists())

    def test_runs_only_the_named_read_only_probe_and_checks_run_id(self):
        df_dir, _save_dir, runner = self.validate()
        values, report = smoke.run_smoke(
            df_dir, runner, "region_test", timeout_seconds=5
        )
        self.assertEqual(values["format"], smoke.REPORT_FORMAT)
        self.assertEqual(values["map_loaded"], "true")
        self.assertEqual(values["orders_status"], "ok")
        self.assertTrue(report.is_file())
        self.assertRegex(report.name, r"^antfarm_live_smoke_[0-9a-f]{32}\.txt$")
        self.assertEqual((df_dir / "runner.calls").read_text(), "called\n")

    def test_refuses_to_treat_a_title_screen_as_a_live_fort(self):
        runner = self.df_dir / smoke.RUNNER_NAME
        runner.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf 'format=antfarm-live-smoke-v1\\nrun_id=%s\\n"
            "map_loaded=false\\nloaded_save_matches=false\\n"
            "loaded_save_folder=unknown\\n' \"$2\" > "
            "antfarm_live_smoke_\"$2\".txt\n",
            encoding="utf-8",
        )
        runner.chmod(0o755)
        native_runner = self.df_dir / "hack" / "dfhack-run"
        native_runner.chmod(0o644)
        with self.assertRaisesRegex(smoke.SmokeError, "native DFHack RPC client"):
            self.validate()
        native_runner.chmod(0o755)
        df_dir, _save_dir, runner = self.validate()
        with self.assertRaisesRegex(smoke.SmokeError, "no fortress map is loaded"):
            smoke.run_smoke(df_dir, runner, "region_test", timeout_seconds=5)

    def test_rejects_when_the_loaded_game_is_a_different_save_folder(self):
        runner = self.df_dir / smoke.RUNNER_NAME
        runner.write_text(
            "#!/bin/sh\\n"
            "set -eu\\n"
            "printf 'format=antfarm-live-smoke-v1\\\\nrun_id=%s\\\\n"
            "map_loaded=true\\\\nloaded_save_matches=false\\\\n"
            "loaded_save_folder=region_primary\\\\n' \\"$2\\" > "
            "antfarm_live_smoke_\\"$2\\".txt\\n",
            encoding="utf-8",
        )
        runner.chmod(0o755)
        df_dir, _save_dir, runner = self.validate()
        with self.assertRaisesRegex(smoke.SmokeError, "not the selected disposable region"):
            smoke.run_smoke(df_dir, runner, "region_test", timeout_seconds=5)

    def test_refuses_a_symlinked_world_save(self):
        world_save = self.save_dir / "world.sav"
        world_save.unlink()
        outside = Path(self.temp.name) / "world.sav"
        outside.write_text("not the disposable save\\n", encoding="utf-8")
        world_save.symlink_to(outside)
        with self.assertRaisesRegex(smoke.SmokeError, "world.sav is required"):
            self.validate()

    def test_live_probe_lua_uses_only_read_only_module_entrypoints(self):
        lua = (ROOT / "game" / smoke.LUA_SCRIPT).read_text(encoding="utf-8")
        self.assertIn("module_report('antfarm_orders', 'audit')", lua)
        self.assertIn("module_report('antfarm_quarters', 'report')", lua)
        self.assertIn("module_report('antfarm_checklist', 'report')", lua)
        self.assertNotIn("dfhack.run_command", lua)
        self.assertNotIn("constructBuilding", lua)
        self.assertNotIn("setOwner", lua)
        self.assertNotIn("status.validated =", lua)
        self.assertNotIn("status.active =", lua)


if __name__ == "__main__":
    unittest.main()
