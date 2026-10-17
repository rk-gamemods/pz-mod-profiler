# Local project recovery archive

Verified backup before local disk cleanup. Existing repository visibility and default branches were preserved. Generated dependencies, build output, and explicitly listed test-generated data were omitted.

Join the numbered recovery parts in filename order into `recovery.tar.gz`, verify its SHA-256 in `BACKUP-MANIFEST.json`, and extract it. `manifest.json` maps original roots, saved files and their SHA-256 hashes, exclusions, retained local files, Git bundle histories and worktree HEADs. Restore each Git repository from its listed bundle and HEAD, then apply its overlay directory and recorded deletions. Bare repositories use their bundle. Non-Git sources are entirely in their overlay directory.

Local credentials and reparse points listed as retained were not removed.
