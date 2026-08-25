#!/usr/bin/env python3
r"""Mirror the working site into the git publish clone, ready to commit and push.

Workflow this supports:
    (work in Desktop\...\float-site)
    python make_plots.py
    matlab -batch export_data
    python publish.py            <- this step
    ...then review + Push in GitHub Desktop

Why not just copy the folder over the top? Because the per-profile figures carry
the profile number and date in their FILENAME (..._profile_039_2026-08-24.png), so
every refresh writes a NEW name. A plain copy leaves last week's file behind, and
the repo slowly fills with orphaned PNGs that nothing references. This mirrors
instead: it copies what changed AND deletes what no longer exists.

It never runs git. Nothing is pushed, nothing is committed — you review the diff in
GitHub Desktop and publish when happy.

Usage:
    python publish.py --dry-run      # show what would change (do this first)
    python publish.py
    python publish.py --force        # discard clone-side edits (not recoverable)
    python publish.py --repo D:\somewhere\else
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
DEFAULT_REPO = Path.home() / "Documents" / "git_repos" / "float-site"

# Never copied out of the working folder (generated, or local-only).
SKIP_NAMES = {".git", "__pycache__", "float_status.html"}
SKIP_SUFFIX = {".pyc"}

# Lives only in the repo and must survive the mirror (git's own metadata and
# whatever GitHub Desktop put there).
REPO_ONLY = {".git", ".gitattributes"}


def wanted(rel: Path) -> bool:
    if any(part in SKIP_NAMES for part in rel.parts):
        return False
    return rel.suffix not in SKIP_SUFFIX


def source_files() -> set[Path]:
    return {p.relative_to(SITE) for p in SITE.rglob("*")
            if p.is_file() and wanted(p.relative_to(SITE))}


def repo_files(repo: Path) -> set[Path]:
    """Files in the clone that this mirror is responsible for.

    Anything git ignores (the single-file build, __pycache__) is deliberately left
    out: it is not ours to delete just because it is not in the source folder."""
    out = set()
    for p in repo.rglob("*"):
        rel = p.relative_to(repo)
        if any(part in REPO_ONLY for part in rel.parts):
            continue
        if not wanted(rel):
            continue
        if p.is_file():
            out.add(rel)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", type=Path, default=DEFAULT_REPO,
                    help=f"publish clone (default: {DEFAULT_REPO})")
    ap.add_argument("--dry-run", action="store_true", help="report only, change nothing")
    ap.add_argument("--force", action="store_true",
                    help="overwrite clone-side edits (they are NOT recoverable)")
    args = ap.parse_args()

    repo: Path = args.repo.expanduser().resolve()
    if not repo.is_dir():
        raise SystemExit(f"publish clone not found: {repo}")
    if not (repo / ".git").exists():
        raise SystemExit(f"not a git repository (no .git): {repo}\n"
                         "Refusing to write — point --repo at the clone.")
    if repo == SITE:
        raise SystemExit("source and destination are the same folder")

    src, dst = source_files(), repo_files(repo)

    new     = sorted(src - dst)
    gone    = sorted(dst - src)
    common  = sorted(src & dst)
    changed = [r for r in common
               if not filecmp.cmp(SITE / r, repo / r, shallow=False)]

    # Refuse to silently destroy work edited in the clone. If a destination file
    # differs AND is newer than the source, someone edited it there -- overwriting
    # it loses that edit for good when the file is untracked by git.
    edited = [r for r in changed
              if (repo / r).stat().st_mtime > (SITE / r).stat().st_mtime + 1]
    if edited and not args.force:
        err = sys.stderr
        print("STOP: these files were edited in the publish clone, not in "
              "the working folder:", file=err)
        for r in edited:
            print("    " + r.as_posix(), file=err)
        print("", file=err)
        print("Mirroring would overwrite them and the change would be lost.", file=err)
        print("Copy the newer version back into the working folder first:", file=err)
        print("    " + str(SITE), file=err)
        print("then re-run. To discard those edits instead, re-run with --force.", file=err)
        return 2

    tag = "would " if args.dry_run else ""
    for r in new:     print(f"  + {tag}add     {r.as_posix()}")
    for r in changed: print(f"  ~ {tag}update  {r.as_posix()}")
    for r in gone:    print(f"  - {tag}delete  {r.as_posix()}")

    if not args.dry_run:
        for r in new + changed:
            (repo / r).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SITE / r, repo / r)
        for r in gone:
            (repo / r).unlink()
        # drop directories the deletions emptied
        for d in sorted((p for p in repo.rglob("*") if p.is_dir()),
                        key=lambda p: len(p.parts), reverse=True):
            if any(part in REPO_ONLY for part in d.relative_to(repo).parts):
                continue
            if not any(d.iterdir()):
                d.rmdir()

    total = len(new) + len(changed) + len(gone)
    print(f"\n{repo}")
    if total == 0:
        print("already in sync — nothing to do.")
    else:
        print(f"{len(new)} added, {len(changed)} updated, {len(gone)} deleted"
              + (" (dry run - nothing written)" if args.dry_run else ""))
        if not args.dry_run:
            print("next: review the diff in GitHub Desktop, then Commit + Push.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
