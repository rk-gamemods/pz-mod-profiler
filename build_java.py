#!/usr/bin/env python3
"""build_java.py — compile the ZBPerfBridge companion JAR.

Requires:
  - JDK 17+ (javac on PATH)
  - ZombieBuddy.jar in the PZ game directory (compile-only, for @Exposer.LuaClass)

Output:  media/java/00_ModProfiler.jar
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
JAVA_SRC = SCRIPT_DIR / "java" / "src"
JAR_OUTPUT = SCRIPT_DIR / "media" / "java" / "00_ModProfiler.jar"

# ZombieBuddy.jar locations (checked in order)
ZB_JAR_CANDIDATES = [
    Path(r"C:\Steam\steamapps\common\ProjectZomboid\ZombieBuddy.jar"),
    SCRIPT_DIR.parent / "ZombieBuddy" / "java" / "build" / "libs" / "ZombieBuddy.jar",
]


def find_zb_jar() -> Path:
    for p in ZB_JAR_CANDIDATES:
        if p.is_file():
            return p
    sys.exit(
        "ERROR: ZombieBuddy.jar not found. Checked:\n"
        + "\n".join(f"  {p}" for p in ZB_JAR_CANDIDATES)
    )


def find_javac() -> str:
    javac = shutil.which("javac")
    if javac:
        return javac
    sys.exit("ERROR: javac not found on PATH. Install a JDK (17+).")


def find_jar_tool() -> str:
    jar = shutil.which("jar")
    if jar:
        return jar
    sys.exit("ERROR: jar tool not found on PATH. Install a JDK (17+).")


def build() -> None:
    javac = find_javac()
    jar_tool = find_jar_tool()
    zb_jar = find_zb_jar()

    # Collect .java sources
    sources = list(JAVA_SRC.rglob("*.java"))
    if not sources:
        sys.exit(f"ERROR: no .java files found under {JAVA_SRC}")

    print(f"  javac: {javac}")
    print(f"  ZombieBuddy.jar: {zb_jar}")
    print(f"  sources: {len(sources)} file(s)")

    with tempfile.TemporaryDirectory() as tmp:
        classes_dir = Path(tmp) / "classes"
        classes_dir.mkdir()

        # Compile
        cmd = [
            javac,
            "-source", "17",
            "-target", "17",
            "-cp", str(zb_jar),
            "-d", str(classes_dir),
        ] + [str(s) for s in sources]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print("COMPILE ERROR:")
            print(result.stderr)
            sys.exit(1)
        if result.stderr:
            print(result.stderr)

        # Package JAR
        JAR_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        jar_cmd = [
            jar_tool, "cf", str(JAR_OUTPUT),
            "-C", str(classes_dir), ".",
        ]
        result = subprocess.run(jar_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print("JAR ERROR:")
            print(result.stderr)
            sys.exit(1)

    size_kb = JAR_OUTPUT.stat().st_size / 1024
    print(f"  output: {JAR_OUTPUT} ({size_kb:.1f} KB)")


if __name__ == "__main__":
    print("--- Build Java companion ---")
    build()
    print("  done")
