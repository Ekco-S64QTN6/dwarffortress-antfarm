#!/usr/bin/env python3
"""Run a deliberately read-only DFHack smoke probe against a marked disposable save.

This is not part of tests/run_all.sh. The in-game DFHack process must already be
running with the selected disposable fortress loaded.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Sequence


MARKER_NAME = ".antfarm-disposable-save"
MARKER_CONTENT = (
    "I UNDERSTAND THIS IS A DISPOSABLE ANT FARM TEST SAVE.\n"
)
RUNNER_NAME = "dfhack-run"
LUA_SCRIPT = Path("hack") / "scripts" / "antfarm_live_smoke.lua"
REPORT_PREFIX = "antfarm_live_smoke_"
REPORT_FORMAT = "antfarm-live-smoke-v1"
REGION_RE = re.compile(r"^[A-Za-z0-9_-]+$")


class SmokeError(RuntimeError):
    """A safety gate or live probe failed."""


def _parse_report(path: Path, expected_run_id: str) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SmokeError(f"DFHack did not write the expected report: {path}: {exc}") from exc

    values: dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        if not line or "=" not in line:
            raise SmokeError(f"malformed report line {line_number}: {line!r}")
        key, value = line.split("=", 1)
        if not key or key in values:
            raise SmokeError(f"empty or duplicate report key on line {line_number}")
        values[key] = value

    if values.get("format") != REPORT_FORMAT:
        raise SmokeError("report format is missing or unsupported")
    if values.get("run_id") != expected_run_id:
        raise SmokeError("report run id does not match this invocation")
    if values.get("map_loaded") not in {"true", "false"}:
        raise SmokeError("report has no valid map_loaded state")
    return values


def validate_target(
    df_dir_arg: str,
    region: str,
    confirm_disposable: bool,
    confirm_loaded_save: bool,
) -> tuple[Path, Path, Path]:
    if not confirm_disposable or not confirm_loaded_save:
        raise SmokeError(
            "two explicit acknowledgements are required: "
            "--confirm-disposable and --confirm-loaded-save"
        )
    if not REGION_RE.fullmatch(region) or region == "current":
        raise SmokeError("region must be one safe save-folder name (not 'current')")

    try:
        df_dir = Path(df_dir_arg).expanduser().resolve(strict=True)
    except OSError as exc:
        raise SmokeError(f"Dwarf Fortress directory does not exist: {exc}") from exc
    if not df_dir.is_dir():
        raise SmokeError(f"not a Dwarf Fortress directory: {df_dir}")

    try:
        save_root = (df_dir / "data" / "save").resolve(strict=True)
        save_dir = (save_root / region).resolve(strict=True)
    except OSError as exc:
        raise SmokeError(f"save root or selected region does not exist: {exc}") from exc
    if save_dir.parent != save_root or not save_dir.is_dir():
        raise SmokeError("selected region is not a direct folder under data/save")
    world_save = save_dir / "world.sav"
    if world_save.is_symlink() or not world_save.is_file():
        raise SmokeError(
            f"{region} is not an existing fortress save (world.sav is required); "
            "generated world.dat files are not accepted"
        )

    marker = save_dir / MARKER_NAME
    if marker.is_symlink() or not marker.is_file():
        raise SmokeError(
            f"missing required disposable-save marker: {marker}\n"
            f"Create it manually only inside a disposable test save with: "
            f"printf '%s' {MARKER_CONTENT.strip()!r} > {marker}"
        )
    try:
        marker_content = marker.read_text(encoding="utf-8")
    except OSError as exc:
        raise SmokeError(f"cannot read disposable-save marker: {exc}") from exc
    if marker_content != MARKER_CONTENT:
        raise SmokeError(
            f"{marker} must contain exactly: {MARKER_CONTENT.strip()}"
        )

    runner = df_dir / RUNNER_NAME
    if not runner.is_file() or not os.access(runner, os.X_OK):
        raise SmokeError(f"executable DFHack wrapper not found: {runner}")
    native_runner = df_dir / "hack" / "dfhack-run"
    if not native_runner.is_file() or not os.access(native_runner, os.X_OK):
        raise SmokeError(f"native DFHack RPC client not found or not executable: {native_runner}")
    lua_script = df_dir / LUA_SCRIPT
    if not lua_script.is_file():
        raise SmokeError(
            f"live-smoke Lua script not installed: {lua_script}; "
            "install the repository's game/hack/scripts into this DFHack scripts folder"
        )
    return df_dir, save_dir, runner


def run_smoke(
    df_dir: Path,
    runner: Path,
    timeout_seconds: int,
) -> tuple[dict[str, str], Path]:
    run_id = uuid.uuid4().hex
    report_path = df_dir / f"{REPORT_PREFIX}{run_id}.txt"
    if report_path.exists():
        raise SmokeError("unexpected report-path collision; refusing to overwrite")

    command = [str(runner), "antfarm_live_smoke", run_id]
    try:
        completed = subprocess.run(
            command,
            cwd=str(df_dir),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise SmokeError(
            f"DFHack did not answer within {timeout_seconds}s. "
            "Confirm the game is running and its local RPC listener is enabled."
        ) from exc
    except OSError as exc:
        raise SmokeError(f"could not execute dfhack-run: {exc}") from exc

    if completed.stdout.strip():
        print("dfhack-run stdout:")
        print(completed.stdout.rstrip())
    if completed.stderr.strip():
        print("dfhack-run stderr:")
        print(completed.stderr.rstrip())
    if completed.returncode != 0:
        raise SmokeError(f"dfhack-run exited with status {completed.returncode}")

    values = _parse_report(report_path, run_id)
    if values["map_loaded"] != "true":
        raise SmokeError(
            "DFHack answered, but no fortress map is loaded. Load the marked "
            "disposable fortress before running this read-only probe."
        )
    return values, report_path


def print_summary(values: dict[str, str], report_path: Path) -> None:
    print("\nAntfarm live-smoke report (aggregate/read-only)")
    fields = (
        "df_version",
        "dfhack_version",
        "game_year",
        "game_paused",
        "citizens",
        "beds",
        "bedrooms_defined",
        "beds_owned",
        "unhoused",
        "doors",
        "chests",
        "cabinets",
        "orders_total",
        "orders_validated",
        "orders_unvalidated",
        "orders_validation_unknown",
        "orders_stalled_jobs",
        "orders_unmet_requirements",
        "manager_office_status",
        "checklist_pass",
        "checklist_fail",
        "checklist_todo",
        "checklist_warn",
    )
    for key in fields:
        if key in values:
            print(f"  {key}: {values[key]}")
    for area in ("orders", "quarters", "checklist"):
        if values.get(f"{area}_status") != "ok":
            print(f"  WARNING {area}: {values.get(f'{area}_status', 'missing')}")
            detail = values.get(f"{area}_error")
            if detail:
                print(f"    {detail}")
    print(f"\nFull report: {report_path}")
    print(
        "This is evidence from the currently loaded game, not proof of long-term "
        "production or room completion."
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run aggregate-only, read-only DFHack diagnostics against a marked "
            "disposable fortress that is already loaded in the running game."
        )
    )
    parser.add_argument("--df-dir", required=True, help="Dwarf Fortress installation directory")
    parser.add_argument("--region", required=True, help="marked save folder under data/save")
    parser.add_argument(
        "--confirm-disposable",
        action="store_true",
        help="confirm the selected save folder is disposable",
    )
    parser.add_argument(
        "--confirm-loaded-save",
        action="store_true",
        help="confirm this exact marked disposable save is currently loaded in DF",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=45,
        help="RPC timeout in seconds (default: 45; allowed: 5..120)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not 5 <= args.timeout <= 120:
        print("ERROR: --timeout must be between 5 and 120 seconds", file=sys.stderr)
        return 2
    try:
        df_dir, _save_dir, runner = validate_target(
            args.df_dir,
            args.region,
            args.confirm_disposable,
            args.confirm_loaded_save,
        )
        values, report_path = run_smoke(df_dir, runner, args.timeout)
    except SmokeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print_summary(values, report_path)
    unavailable = [
        area for area in ("orders", "quarters", "checklist")
        if values.get(f"{area}_status") != "ok"
    ]
    if unavailable:
        print(
            "ERROR: the live probe ran, but required report modules failed: "
            + ", ".join(unavailable),
            file=sys.stderr,
        )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
