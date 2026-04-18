from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import sys


@dataclass(frozen=True)
class TokenContract:
    description: str
    source_file: str
    source_needle: str
    token: str
    scopes: tuple[str, ...]


@dataclass(frozen=True)
class PathContract:
    description: str
    source_file: str
    source_needle: str
    required_path: str


TOKEN_CONTRACTS = (
    TokenContract(
        description="timestamp global used by profiler engine",
        source_file="media/lua/shared/00_ModProfiler/ModProfiler.lua",
        source_needle="getTimestampMs",
        token="getTimestampMs",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="closure filename helper used by wrapper registration",
        source_file="media/lua/shared/00_ModProfiler/ModProfiler.lua",
        source_needle="getFilenameOfClosure",
        token="getFilenameOfClosure",
        scopes=("Java/source",),
    ),
    TokenContract(
        description="closure line helper used by wrapper registration",
        source_file="media/lua/shared/00_ModProfiler/ModProfiler.lua",
        source_needle="getFirstLineOfClosure",
        token="getFirstLineOfClosure",
        scopes=("Java/source",),
    ),
    TokenContract(
        description="CPU timing API used by frame-budget display",
        source_file="media/lua/shared/00_ModProfiler/ModProfiler.lua",
        source_needle="getCPUTime",
        token="getCPUTime",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="performance object accessor",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="getPerformance",
        token="getPerformance",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="framerate accessor on performance object",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="getFramerate",
        token="getFramerate",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="uncapped-framerate accessor on performance object",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="isFramerateUncapped",
        token="isFramerateUncapped",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="clipboard API used by row right-click",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="Clipboard.setClipboard",
        token="Clipboard.setClipboard",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="file reader API used by INI load",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="getFileReader",
        token="getFileReader",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="file writer API used by INI save",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="getFileWriter",
        token="getFileWriter",
        scopes=("Java/source", "Lua"),
    ),
    TokenContract(
        description="core accessor used for sizing",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle="getCore",
        token="getCore",
        scopes=("Java/source", "Lua"),
    ),
)

PATH_CONTRACTS = (
    PathContract(
        description="ISCollapsableWindow base file exists in stored Lua codebase",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle='require "ISUI/ISCollapsableWindow"',
        required_path="Lua/client/ISUI/ISCollapsableWindow.lua",
    ),
    PathContract(
        description="ISComboBox base file exists in stored Lua codebase",
        source_file="media/lua/client/00_ModProfiler/ModProfilerUI.lua",
        source_needle='require "ISUI/ISComboBox"',
        required_path="Lua/client/ISUI/ISComboBox.lua",
    ),
)


class PZCodebaseConnector:
    def __init__(self, root: Path) -> None:
        self.root = root

    @classmethod
    def detect(cls, repo_root: Path) -> "PZCodebaseConnector":
        env_root = os.getenv("PZ_CODEBASE_ROOT")
        candidates = [
            Path(env_root) if env_root else None,
            repo_root.parent / "PZCodebase",
            Path(r"C:\Users\Admin\Documents\GIT\GameMods\PZMods\PZCodebase"),
            Path(r"C:\Users\Admin\Documents\GIT\GameMods\PZCodebase"),
        ]
        for candidate in candidates:
            if not candidate:
                continue
            if (candidate / "Java" / "source").is_dir() and (candidate / "Lua").is_dir():
                return cls(candidate)
        raise FileNotFoundError("Could not locate stored PZCodebase. Set PZ_CODEBASE_ROOT or place it under ../PZCodebase.")

    def find_token(self, token: str, scopes: tuple[str, ...]) -> str | None:
        for scope in scopes:
            scope_root = self.root / scope
            if not scope_root.exists():
                continue
            for path in sorted(scope_root.rglob("*")):
                if not path.is_file():
                    continue
                if path.suffix.lower() not in {".java", ".lua", ".txt"}:
                    continue
                try:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                if token in text:
                    return str(path.relative_to(self.root))
        return None

    def require_path(self, rel_path: str) -> bool:
        return (self.root / rel_path).exists()


def validate_contracts(repo_root: Path, connector: PZCodebaseConnector) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    details: list[str] = [f"Using PZCodebase root: {connector.root}"]

    for contract in TOKEN_CONTRACTS:
        source_path = repo_root / contract.source_file
        if not source_path.is_file():
            errors.append(f"Missing source file for contract: {contract.source_file}")
            continue
        source_text = source_path.read_text(encoding="utf-8")
        if contract.source_needle not in source_text:
            errors.append(
                f"Contract source drift: {contract.source_needle!r} not found in {contract.source_file} ({contract.description})"
            )
            continue
        match = connector.find_token(contract.token, contract.scopes)
        if not match:
            errors.append(
                f"Codebase token missing: {contract.token!r} for {contract.description}"
            )
        else:
            details.append(f"OK token {contract.token} -> {match}")

    for contract in PATH_CONTRACTS:
        source_path = repo_root / contract.source_file
        if not source_path.is_file():
            errors.append(f"Missing source file for contract: {contract.source_file}")
            continue
        source_text = source_path.read_text(encoding="utf-8")
        if contract.source_needle not in source_text:
            errors.append(
                f"Contract source drift: {contract.source_needle!r} not found in {contract.source_file} ({contract.description})"
            )
            continue
        if not connector.require_path(contract.required_path):
            errors.append(
                f"Codebase path missing: {contract.required_path} for {contract.description}"
            )
        else:
            details.append(f"OK path {contract.required_path}")

    return errors, details


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    connector = PZCodebaseConnector.detect(repo_root)
    errors, details = validate_contracts(repo_root, connector)
    for detail in details:
        print(detail)
    if errors:
        print("\nAPI contract validation failed:")
        for err in errors:
            print(f"- {err}")
        return 1
    print("\nAPI contract validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
