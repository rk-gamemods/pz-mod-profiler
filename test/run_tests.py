from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import sys

from validate_pz_api_contracts import PZCodebaseConnector, validate_contracts


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parent
LUA_FILES = (
    REPO_ROOT / "media" / "lua" / "shared" / "00_ModProfiler" / "ModProfiler.lua",
    REPO_ROOT / "media" / "lua" / "client" / "00_ModProfiler" / "ModProfilerUI.lua",
    REPO_ROOT / "media" / "lua" / "client" / "00_ModProfiler" / "ModProfilerKeys.lua",
)


def find_lua_executable() -> str:
    candidates = [
        os.getenv("PZ_LUA_EXE"),
        os.getenv("LUA_EXE"),
        r"C:\Users\Admin\AppData\Local\Programs\Lua\bin\lua.exe",
        shutil.which("lua"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    raise FileNotFoundError("Lua executable not found. Set PZ_LUA_EXE or LUA_EXE.")


def run_command(args: list[str], label: str) -> None:
    print(f"\n== {label} ==")
    print("+ " + " ".join(args))
    result = subprocess.run(args, cwd=REPO_ROOT, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def compile_lua_sources(lua_exe: str) -> None:
    for path in LUA_FILES:
        rel = path.relative_to(REPO_ROOT).as_posix()
        run_command([lua_exe, "-e", f"assert(loadfile([[{rel}]]))"], f"Compile {rel}")


def run_lua_unit_tests(lua_exe: str) -> None:
    run_command([lua_exe, "test/lua/run_unit_tests.lua"], "Lua unit tests")


def run_codebase_validation() -> None:
    print("\n== PZ codebase API validation ==")
    connector = PZCodebaseConnector.detect(REPO_ROOT)
    errors, details = validate_contracts(REPO_ROOT, connector)
    for detail in details:
        print(detail)
    if errors:
        print("\nAPI contract validation failed:")
        for err in errors:
            print(f"- {err}")
        raise SystemExit(1)
    print("\nAPI contract validation passed")


def main() -> int:
    lua_exe = find_lua_executable()
    compile_lua_sources(lua_exe)
    run_lua_unit_tests(lua_exe)
    run_codebase_validation()
    print("\nAll tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
