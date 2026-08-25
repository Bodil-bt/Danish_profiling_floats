#!/usr/bin/env python3
"""Collect the pipeline's per-float figures into float-site/assets/plots/.

The pipeline (../pipeline) is treated as READ-ONLY: this script only opens files
there for reading and never creates, edits or deletes anything inside it.
Everything written lands under float-site/assets/plots/.

Two kinds of source figure are handled:
  *.pdf  -> rendered to PNG with PyMuPDF (one PNG per page; multi-page files get
            a _p<N> suffix)
  *.png  -> copied as-is

Per float it picks up the trajectory map and the depth-vs-time section figure, plus
the most recent per-profile figure from <float_dir>/profiles/.

Usage:
    python make_plots.py                 # all floats, latest profile figure each
    python make_plots.py --profiles 4
    python make_plots.py --float 2903997 --float Sgav_provor
    python make_plots.py --gdac          # also include the parallel GDAC product
    python make_plots.py --clean         # wipe assets/plots first

Requires: PyMuPDF (pip install pymupdf) -- only if there are PDFs to convert.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

SITE_DIR = Path(__file__).resolve().parent
REPO_ROOT = SITE_DIR.parent
PIPELINE_DATA = REPO_ROOT / "pipeline" / "data"
OUT_ROOT = SITE_DIR / "assets" / "plots"

# Directories under pipeline/data that are not floats.
SKIP_DIRS = {"_sbd_staging", "share_out"}

# Fleet-level figures, in the order they should appear on the site.
# The pipeline also writes a "<id>_profiles" ascent-overlay + T-S figure; the site
# does not show it, so it is not collected. Add "_profiles" here to bring it back.
FLEET_SUFFIXES = ("_map", "_sections")

PDF_DPI = 150


def guard_output(path: Path) -> None:
    """Refuse to write anywhere outside float-site/assets/plots."""
    try:
        path.resolve().relative_to(OUT_ROOT)
    except ValueError:
        raise SystemExit(f"refusing to write outside {OUT_ROOT}: {path}")


def float_dirs(only: list[str] | None) -> list[Path]:
    if not PIPELINE_DATA.is_dir():
        raise SystemExit(f"pipeline data folder not found: {PIPELINE_DATA}")
    dirs = [
        d
        for d in sorted(PIPELINE_DATA.iterdir())
        if d.is_dir() and d.name not in SKIP_DIRS and not d.name.startswith(".")
    ]
    if only:
        wanted = {s.lower() for s in only}
        dirs = [d for d in dirs if d.name.lower() in wanted]
        missing = wanted - {d.name.lower() for d in dirs}
        for m in sorted(missing):
            print(f"  ! no such float folder: {m}", file=sys.stderr)
    return dirs


def profile_sort_key(p: Path):
    """Sort per-profile figures by their embedded profile number, then name."""
    m = re.search(r"_profile_(\d+)", p.name)
    return (int(m.group(1)) if m else -1, p.name)


def gather_sources(fdir: Path, n_profiles: int, include_gdac: bool) -> list[tuple[Path, str]]:
    """Source figures for one float, as (path, prefix).

    The GDAC add-on writes figures with the SAME basenames as the primary
    SBD-decoded product, so its outputs get a `gdac_` prefix to keep both."""
    fid = fdir.name
    found: list[tuple[Path, str]] = []

    roots = [(fdir, "")]
    if include_gdac and (fdir / "gdac").is_dir():
        roots.append((fdir / "gdac", "gdac_"))

    for root, prefix in roots:
        for suffix in FLEET_SUFFIXES:
            # PNG wins over PDF when the pipeline wrote both for the same figure.
            hits = [root / f"{fid}{suffix}{ext}" for ext in (".png", ".pdf")]
            hit = next((h for h in hits if h.is_file()), None)
            if hit is not None:
                found.append((hit, prefix))

        pdir = root / "profiles"
        if n_profiles and pdir.is_dir():
            figs = sorted(
                (p for p in pdir.iterdir() if p.suffix.lower() in (".png", ".pdf")),
                key=profile_sort_key,
            )
            for p in figs[-n_profiles:]:
                found.append((p, prefix))

    return found


def convert_pdf(src: Path, out_dir: Path, prefix: str = "") -> list[Path]:
    try:
        import pymupdf  # type: ignore
    except ImportError:  # pragma: no cover - depends on the local install
        try:
            import fitz as pymupdf  # type: ignore
        except ImportError:
            raise SystemExit(
                f"{src.name} is a PDF but PyMuPDF is not installed "
                "-- run: pip install pymupdf"
            )

    written: list[Path] = []
    with pymupdf.open(src) as doc:  # opened read-only; never saved back
        multi = doc.page_count > 1
        for i, page in enumerate(doc, start=1):
            stem = f"{src.stem}_p{i}" if multi else src.stem
            dst = out_dir / f"{prefix}{stem}.png"
            guard_output(dst)
            page.get_pixmap(dpi=PDF_DPI).save(dst)
            written.append(dst)
    return written


def copy_png(src: Path, out_dir: Path, prefix: str = "") -> list[Path]:
    dst = out_dir / f"{prefix}{src.name}"
    guard_output(dst)
    if dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime:
        return [dst]  # already up to date (still counts as kept, not pruned)
    shutil.copyfile(src, dst)
    return [dst]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profiles", type=int, default=1,
                    help="how many of the newest per-profile figures to include (0 = none)")
    ap.add_argument("--float", dest="floats", action="append",
                    help="limit to this float id (repeatable)")
    ap.add_argument("--gdac", action="store_true",
                    help="also include figures from the parallel GDAC product")
    ap.add_argument("--clean", action="store_true",
                    help="delete assets/plots before rebuilding")
    args = ap.parse_args()

    if args.clean and OUT_ROOT.exists():
        guard_output(OUT_ROOT / "x")
        shutil.rmtree(OUT_ROOT)
        print(f"cleaned {OUT_ROOT}")

    OUT_ROOT.mkdir(parents=True, exist_ok=True)

    total_src = total_out = 0
    for fdir in float_dirs(args.floats):
        sources = gather_sources(fdir, args.profiles, args.gdac)
        if not sources:
            print(f"{fdir.name}: no figures found -- skipped")
            continue

        out_dir = OUT_ROOT / fdir.name
        guard_output(out_dir / "x")
        out_dir.mkdir(parents=True, exist_ok=True)

        n_pdf = 0
        written: list[Path] = []
        for src, prefix in sources:
            if src.suffix.lower() == ".pdf":
                written += convert_pdf(src, out_dir, prefix)
                n_pdf += 1
            else:
                written += copy_png(src, out_dir, prefix)

        # Prune superseded figures. The per-profile figure carries the profile
        # number and date in its FILENAME, so when a float surfaces again the new
        # figure lands beside the old one instead of replacing it -- and
        # export_data.m, which lists whatever is in this folder, would then show
        # two "latest" profiles. Anything not written this run no longer belongs.
        keep = {w.resolve() for w in written}
        removed = 0
        for old_file in out_dir.iterdir():
            if old_file.is_file() and old_file.resolve() not in keep:
                guard_output(old_file)
                old_file.unlink()
                removed += 1

        total_src += len(sources)
        total_out += len(written)
        extra = f" ({n_pdf} converted from PDF)" if n_pdf else ""
        if removed:
            extra += f" (-{removed} superseded)"
        print(f"{fdir.name}: {len(written)} PNG in assets/plots/{fdir.name}/{extra}")

    print(f"\ndone: {total_src} source figure(s) -> {total_out} PNG under {OUT_ROOT}")
    print("next: run export_data.m in MATLAB to regenerate data.js")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
