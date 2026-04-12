#!/usr/bin/env python3
"""deploy.py — sync release folder and deploy to Zomboid mods directory.

Usage:
    python deploy.py              # deploy
    python deploy.py --verify     # deploy then hash-verify source vs live
"""

import hashlib
import re
import shutil
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
MODS_DIR = Path(r"C:\Users\Admin\Zomboid\mods")
MOD_NAME = "00_ModProfiler"
VERSION_DIR = "42.0"


def mirror(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def deploy() -> None:
    mod_root = SCRIPT_DIR
    src_media = mod_root / "media"
    mod_info = mod_root / "mod.info"
    release_root = mod_root / "release" / MOD_NAME
    release_media = release_root / VERSION_DIR / "media"
    live_dir = MODS_DIR / MOD_NAME

    if not src_media.is_dir():
        sys.exit(f"ERROR: source media not found: {src_media}")
    if not mod_info.is_file():
        sys.exit(f"ERROR: mod.info not found: {mod_info}")

    mod_info_text = mod_info.read_text(encoding="utf-8")
    m = re.search(r"versionMin\s*=\s*(\S+)", mod_info_text)
    if not m:
        sys.exit(f"ERROR: no versionMin found in {mod_info}")
    if m.group(1) != VERSION_DIR:
        sys.exit(
            f"ERROR: VERSION_DIR mismatch! deploy.py uses '{VERSION_DIR}' "
            f"but mod.info says versionMin={m.group(1)}."
        )

    print(f"--- {MOD_NAME} ---")
    print(f"  sync media -> release")
    mirror(src_media, release_media)
    shutil.copy2(mod_info, release_root / "mod.info")
    shutil.copy2(mod_info, release_root / VERSION_DIR / "mod.info")

    print(f"  deploy -> {live_dir}")
    mirror(release_root, live_dir)

    if live_dir.is_dir():
        for d in live_dir.iterdir():
            if d.is_dir() and re.match(r"^\d+(\.\d+)?$", d.name) and d.name != VERSION_DIR:
                sys.exit(
                    f"ERROR: stale version dir '{d.name}' in {live_dir}! Delete it."
                )

    print(f"  done")


def file_hash(path: Path) -> str:
    h = hashlib.md5()
    h.update(path.read_bytes())
    return h.hexdigest()


def verify() -> list[str]:
    src_media = SCRIPT_DIR / "media"
    live_media = MODS_DIR / MOD_NAME / VERSION_DIR / "media"
    mismatches = []

    for src_file in src_media.rglob("*"):
        if not src_file.is_file():
            continue
        rel = src_file.relative_to(src_media)
        live_file = live_media / rel
        if not live_file.exists():
            mismatches.append(f"  MISSING in live: {rel}")
        elif file_hash(src_file) != file_hash(live_file):
            mismatches.append(f"  HASH MISMATCH:   {rel}")

    if live_media.is_dir():
        for live_file in live_media.rglob("*"):
            if not live_file.is_file():
                continue
            rel = live_file.relative_to(live_media)
            if not (src_media / rel).exists():
                mismatches.append(f"  EXTRA in live:   {rel}")

    return mismatches


def main() -> None:
    do_verify = "--verify" in sys.argv

    deploy()

    if do_verify:
        print("\n=== Verification ===")
        problems = verify()
        if problems:
            print(f"{MOD_NAME}: {len(problems)} issue(s)")
            for p in problems:
                print(p)
            sys.exit(1)
        else:
            print(f"{MOD_NAME}: OK — all files match")

    print("\nDone. Exit to Desktop before testing.")


if __name__ == "__main__":
    main()
