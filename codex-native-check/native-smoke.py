"""Offline Codex CLI checks; run with Python 3.11+ and an installed Codex CLI."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--codex-js", type=Path, help="npm installation's bin/codex.js")
parser.add_argument("--binary", type=Path, help="standalone Codex executable")
parser.add_argument("--version", default="0.162.1")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if bool(args.codex_js) == bool(args.binary):
    parser.error("specify exactly one of --codex-js or --binary")
command = ([shutil.which("node"), str(args.codex_js.resolve())]
           if args.codex_js else [str(args.binary.resolve())])
checks = []

with tempfile.TemporaryDirectory(prefix="codex-pilot-smoke-", dir=ROOT) as temporary:
    test_root = Path(temporary)
    codex_directory = test_root / "config directory with spaces"
    codex_directory.mkdir()
    config_file = codex_directory / "config.toml"
    original = (ROOT / "config/default.toml").read_text()
    config_file.write_text(original)
    shutil.copyfile(ROOT / "config/pilot.config.toml", codex_directory / "pilot.config.toml")
    environment = os.environ.copy()
    # Select the CLI's documented config directory only in child processes.
    environment["CODEX_HOME"] = str(codex_directory)

    def run(name, arguments, expect_success=True, contains=None, json_check=None):
        result = subprocess.run(command + arguments, cwd=ROOT / "project",
                                env=environment, input="", capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        ok = (result.returncode == 0) == expect_success
        if contains:
            ok = ok and re.search(contains, output, re.MULTILINE) is not None
        if json_check:
            try:
                ok = ok and bool(json_check(json.loads(result.stdout)))
            except (ValueError, KeyError, TypeError):
                ok = False
        checks.append({"name": name, "passed": ok, "exit_code": result.returncode,
                       "stdout": result.stdout, "stderr": result.stderr})
        print(f'{"PASS" if ok else "FAIL"}: {name}', flush=True)
        return result

    run("version", ["--version"], contains=rf"codex-cli {re.escape(args.version)}(?:\s|$)")
    run("strict valid configuration", ["--strict-config", "app-server"])
    run("named configuration overlay", ["--profile", "pilot", "mcp", "list", "--json"],
        json_check=lambda value: any(item.get("name") == "pilot-overlay" for item in value))
    run("valid configuration", ["features", "list"],
        contains=r"^shell_snapshot\s+\S+\s+false$")
    run("command-line configuration override", ["-c",
        "features.shell_snapshot=true", "features", "list"],
        contains=r"^shell_snapshot\s+\S+\s+true$")
    run("empty MCP configuration", ["mcp", "list", "--json"],
        json_check=lambda value: value == [])
    run("persist configuration entry", ["mcp", "add", "pilot-smoke", "--", "node", "--version"])
    run("read persisted configuration entry", ["mcp", "list", "--json"],
        json_check=lambda value: any(item.get("name") == "pilot-smoke" for item in value))
    run("remove configuration entry", ["mcp", "remove", "pilot-smoke"])
    run("configuration entry removed", ["mcp", "list", "--json"], json_check=lambda value: value == [])
    config_file.write_text('pilot_unknown_key = true\n' + original)
    run("reject unknown configuration field", ["--strict-config", "app-server"],
        expect_success=False, contains=r"(?i)unknown|unrecognized|unexpected")
    config_file.write_text('sandbox_mode = "invalid-mode"\n')
    run("reject invalid configuration enum", ["features", "list"],
        expect_success=False, contains=r"(?i)invalid-mode|unknown variant")
    config_file.write_text('sandbox_mode = [\n')
    run("reject malformed TOML", ["features", "list"],
        expect_success=False, contains=r"(?i)toml|parse|invalid")
    config_file.write_text(original)
    run("configuration recovery", ["features", "list"],
        contains=r"^shell_snapshot\s+\S+\s+false$")

report = {"platform": platform.system(), "architecture": platform.machine(),
          "version": args.version, "scope": "offline installation and configuration smoke checks; no model requests or sandbox execution",
          "checks": checks, "passed": all(check["passed"] for check in checks)}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + "\n")
raise SystemExit(0 if report["passed"] else 1)
