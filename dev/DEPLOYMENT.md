# 00_ModProfiler — Deployment

## Pipeline: `deploy.py`

**Always use `deploy.py` to deploy.** Never manually copy files or create junctions.

```powershell
cd C:\Users\Admin\Documents\GIT\GameMods\PZMods\00_ModProfiler
python deploy.py --verify
```

### What it does

1. Copies `media/` → `release/00_ModProfiler/42.0/media/`
2. Copies `mod.info` → `release/` root and `42.0/`
3. Mirrors `release/00_ModProfiler/` → `C:\Users\Admin\Zomboid\mods\00_ModProfiler/`
4. With `--verify`: hash-checks every source file vs deployed file

### Source repo layout

```
00_ModProfiler/
  mod.info          ← root mod metadata
  deploy.py         ← THE deploy command
  media/            ← actual source (edit here)
    lua/client/00_ModProfiler/ModProfilerUI.lua
    lua/client/00_ModProfiler/ModProfilerKeys.lua
    lua/shared/00_ModProfiler/ModProfiler.lua
  release/          ← staging area (deploy.py manages this)
  dev/              ← plans, docs (not deployed)
```

### Rules

- **Edit only in `media/`** — that's the single source of truth
- **Run `python deploy.py --verify`** after every edit before testing
- **Exit to Desktop** before relaunching PZ (Lua `require()` caching)
- **No junctions** — PZ's Java file loader (`LuaManager.LoadDirBase`) crashes on junction chains
- **No manual file copies** to `Zomboid\mods\`
