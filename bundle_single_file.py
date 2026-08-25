#!/usr/bin/env python3
"""Bundle the site into ONE self-contained .html file you can just send to someone.

Takes index.html + data.js + coastline.js + assets/plots/*.png and inlines all of it:
the data and the vector coastline become inline <script>s, and every figure becomes a
base64 data: URI. The result
is a single file with no sibling folders -- mail it, drop it on OneDrive/Teams, or
hand it to a colleague, and it opens by double-click.

Still loaded from the internet: the Leaflet/proj4 libraries, and the OpenStreetMap
tiles used by the Denmark panel. The Greenland panel draws its own vector coastline
and needs no tiles at all. Without a connection the table, figures and fold-outs all
still work, and the map panels show a short "needs internet" note.

PNGs are downscaled to --max-width before embedding, because MATLAB exports at 200 dpi
and the page never displays them wider than ~1100 px. Pass --max-width 0 to embed the
originals untouched.

Usage:
    python bundle_single_file.py                      # -> float_status.html
    python bundle_single_file.py --max-width 1200     # smaller file
    python bundle_single_file.py --max-width 0        # full-resolution figures
    python bundle_single_file.py --out share/status.html

Requires: Pillow (only when downscaling; pip install pillow).
"""

from __future__ import annotations

import argparse
import base64
import io
import pathlib
import re
import sys

SITE = pathlib.Path(__file__).resolve().parent
ASSET_RE = re.compile(r'"(assets/plots/[^"]+?\.png)"')


def encode_png(path: pathlib.Path, max_width: int, stats: dict) -> str:
    raw = path.read_bytes()
    if max_width:
        try:
            from PIL import Image
        except ImportError:
            print("  ! Pillow not installed -- embedding originals "
                  "(pip install pillow, or pass --max-width 0)", file=sys.stderr)
            max_width = 0
    if max_width:
        with Image.open(io.BytesIO(raw)) as im:
            if im.width > max_width:
                h = round(im.height * max_width / im.width)
                im = im.resize((max_width, h), Image.LANCZOS)
                buf = io.BytesIO()
                im.save(buf, format="PNG", optimize=True)
                # Downscaling line art through LANCZOS can produce a BIGGER png than
                # the original, so keep whichever is fewer bytes -- the point of the
                # flag is a smaller file, not a smaller number.
                if buf.tell() < len(raw):
                    raw = buf.getvalue()
                    stats["resized"] += 1
                else:
                    stats["kept"] += 1
    return "data:image/png;base64," + base64.b64encode(raw).decode("ascii")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="float_status.html", help="output file")
    ap.add_argument("--max-width", type=int, default=1600,
                    help="downscale figures wider than this, where doing so actually "
                         "shrinks the file (0 = never resize)")
    args = ap.parse_args()

    html = (SITE / "index.html").read_text(encoding="utf-8")
    data = (SITE / "data.js").read_text(encoding="utf-8")
    # coastline.js is the vector land base for the polar map; it must travel with
    # the single file, otherwise the Greenland map falls back to Mercator + OSM.
    coast_path = SITE / "coastline.js"
    coast = coast_path.read_text(encoding="utf-8") if coast_path.is_file() else None
    if coast is None:
        print("  ! coastline.js missing -- the Greenland map will fall back to "
              "Mercator/OSM in this build (run export_coastline.m)", file=sys.stderr)

    # ---- 1. figures -> data: URIs ------------------------------------------
    cache: dict[str, str] = {}
    missing: list[str] = []
    embedded = [0]
    stats = {"resized": 0, "kept": 0}

    def sub(m: re.Match) -> str:
        rel = m.group(1)
        if rel not in cache:
            p = SITE / rel
            if not p.is_file():
                missing.append(rel)
                cache[rel] = ""
            else:
                cache[rel] = encode_png(p, args.max_width, stats)
                embedded[0] += 1
        return '"' + cache[rel] + '"'

    data = ASSET_RE.sub(sub, data)
    for rel in missing:
        print(f"  ! missing figure, left blank: {rel}", file=sys.stderr)

    # ---- 2. inline the local scripts ---------------------------------------
    def inline(page, name, text):
        tag = '<script src="%s"></script>' % name
        if tag not in page:
            raise SystemExit('could not find %s in index.html' % tag)
        if text is None:
            return page.replace(tag, "")
        safe = text.replace("</script", r"<\/script")   # cannot end the block early
        nl = chr(10)
        return page.replace(tag, "<script>" + nl + safe + nl + "</script>")

    html = inline(html, "coastline.js", coast)
    html = inline(html, "data.js", data)

    html = html.replace(
        "<!DOCTYPE html>",
        "<!DOCTYPE html>\n<!-- SINGLE-FILE BUILD: data and figures are embedded. "
        "Generated by bundle_single_file.py -- edit index.html, not this file. -->", 1)

    out = pathlib.Path(args.out)
    if not out.is_absolute():
        out = SITE / out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")

    mb = out.stat().st_size / 1024 / 1024
    note = ""
    if args.max_width:
        note = f", {stats['resized']} downscaled to {args.max_width}px wide"
        if stats["kept"]:
            note += f" ({stats['kept']} left at full size, resizing made them larger)"
    print(f"embedded {embedded[0]} figure(s)" + note)
    print(f"wrote {out}  ({mb:.1f} MB, single file)")
    if mb > 20:
        print("  note: over 20 MB -- most mail servers will reject it; "
              "try --max-width 1200, or share it via OneDrive/Teams.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
