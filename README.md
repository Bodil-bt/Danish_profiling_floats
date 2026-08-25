# float-site — public status page for the DTU Aqua profiling floats

A static, self-contained website that shares the status of our profiling floats: a
summary table, two interactive maps (Greenland and Denmark/Baltic), and a fold-out per
float with its trajectory and measurement figures.

Each fold-out shows three figures: the **trajectory map**, the **depth-vs-time
sections**, and the **most recent ascent profile**.

`index.html` opens straight from disk — double-click it. There is no build step, no
server, and no `fetch()`; the float data is a plain JavaScript file (`data.js`).
Only the map tiles and the mapping libraries are loaded from the internet.

## Read-only with respect to the pipeline

Nothing in this folder ever writes to `../pipeline`. The pipeline's `.mat` datasets,
its decoded CSVs and its figures are only ever **opened for reading**; every file this
project produces lands under `float-site/`. `make_plots.py` additionally refuses, as a
hard guard, to write anywhere outside `float-site/assets/plots/`.

## Layout

```
float-site/
  index.html            the page — a STATIC TEMPLATE, never regenerated
  data.js               const floatData = [...]  — regenerated weekly
  assets/plots/<id>/    the PNGs shown in the fold-outs — regenerated weekly
  coastline.js          vector land for the polar map (generated ONCE, not weekly)
  make_plots.py         pipeline figures  ->  assets/plots/
  export_data.m         pipeline .mat     ->  data.js
  export_coastline.m    m_map GSHHS       ->  coastline.js
  bundle_single_file.py index.html + data.js + PNGs  ->  ONE shareable .html
  publish.py            mirror this folder into the git publish clone
  float_status.html     the single-file build (generated; safe to delete)
  README.md             this file
```

Only `data.js` and `assets/plots/` change between updates. `index.html` renders whatever
`data.js` contains, so adding or retiring a float needs no HTML edit. `coastline.js` is
static geography — regenerate it only if you want a different map window or more detail.

## Weekly refresh

After the normal pipeline run (`RUN_all_floats`):

```bash
python make_plots.py
```

```bash
matlab -batch export_data
```

Run them in that order — `export_data.m` builds the figure lists in `data.js` by scanning
what `make_plots.py` actually produced, so the page can never point at a missing PNG.

Then publish to the live site (see *Hosting* below):

```bash
python publish.py
```

Or, for a one-file version to hand to someone directly:

```bash
python bundle_single_file.py
```

Useful options:

| command | effect |
|---|---|
| `python make_plots.py --profiles 4` | keep the 4 newest per-profile figures (default 1) |
| `python make_plots.py --float 2903997` | just one float (repeatable) |
| `python make_plots.py --clean` | wipe `assets/plots` and rebuild |
| `python make_plots.py --gdac` | also include the parallel GDAC product's figures |
| `export_data('stale_days', 60)` | how quiet a float must go before it reads *inactive* (default 45 days) |

## Where each value comes from

Per float, `export_data.m` reads `pipeline/data/<id>/float_<id>.mat` and
`pipeline/floats_config.csv`:

- **name, WMO, platform, sensors, notes** — the config registry.
- **location** — the last transmitted GPS fix in `PD` (all fixes considered; the last
  transmission is the last transmission).
- **deployment date** — the date of *ascent profile 1*, taken from the sample table
  (`Stage == 590`, cycle ≥ 1). Using the profile record rather than the first GPS fix
  keeps pre-deployment workshop transmissions out of the date automatically.
- **next surfacing** — for arvor floats, last surfacing plus the nke cycle period read
  from `<id>_Float parameters Message 1.csv` (MC2, or MC3 once the cycle count passes
  MC1) — the same rule `plot_float.m` prints on its map, and the two agree. For other
  platforms, last surfacing plus the median interval of the last ten cycles. The field
  records which of the two was used, and is left blank for inactive floats.
- **profiles** — ascent profiles only (distinct cycles at `Stage == 590`).
- **status** — `active` if the float transmitted within `stale_days`, else `inactive`.
  This is deliberately derived from the data, not from the config's `active` column:
  that column controls whether the pipeline *processes* a float, which is not the same
  as whether the float is alive.
- **region** — which map the marker goes on: latitude ≥ 60° N is `greenland`, everything
  else is `denmark`. Add a `region` column to `floats_config.csv` to override per float.
- **track** — the drift trajectory, thinned to 300 points. This is the one place the
  map-framing outlier filter from `plot_float.m` is applied, so a track does not stretch
  back to a pre-deployment fix in Copenhagen.

## The two map projections

The **Denmark & Baltic** map is an ordinary Web Mercator OpenStreetMap.

The **Greenland** map is drawn in **EPSG:3413** — NSIDC north polar stereographic, true
at 70° N with the central meridian at 45° W, which runs straight down Greenland. Mercator
stretches everything above ~70° N out of all recognition and cannot show the pole at all,
so the polar projection is what makes the northern tracks readable. Reprojection is done
by **proj4** + **proj4leaflet**.

Changing the projection forces a change of basemap, because **OSM tiles are published only
in Web Mercator**. Rather than a polar raster service, the Greenland panel draws its **own
vector land** from `coastline.js`, over a plain sea-coloured background, with a dashed
graticule (parallels every 10°, meridians every 30°).

That choice matters for three reasons:

- **Land and floats cannot drift out of register.** Both go through exactly the same
  projection code, so there is no raster grid to line up. An earlier attempt with NASA
  GIBS polar imagery looked wrong for precisely this reason.
- **No tile server.** The Greenland map works in the offline single-file build.
- **It is the plain cartographic look**, matching the rest of the page rather than
  satellite imagery.

`export_coastline.m` produces `coastline.js` from **the same coastline source the
pipeline's own figures use** — m_map's installed GSHHS (`m_gshhs_i`), falling back to the
bundled `m_coasts.mat`. Defaults: window lon [−120, 60], lat [50, 85], simplified at
0.05°, islands under 0.25° dropped → 647 polygons, ~700 KB.

```bash
matlab -batch export_coastline
```

| command | effect |
|---|---|
| `export_coastline('tol', 0.02, 'minspan', 0.1)` | finer coast, more islands, bigger file |
| `export_coastline('lonlim', [-180 180], 'latlim', [45 85])` | whole Arctic |

If proj4/proj4leaflet fail to load, or `coastline.js` is missing, the Greenland map falls
back to Mercator + OSM rather than breaking. If Leaflet itself is unavailable both panels
show a short "needs internet" note.

## `data.js` schema

```js
const floatUpdated = "2026-08-24 10:19";   // export timestamp, shown in the header

const floatData = [
  {
    id:                   "3902677",           // pipeline/data folder name
    wmo:                  "3902677",
    name:                 "East Greenland",
    platform:             "arvor",             // arvor | pfv2 | provor
    sensors:              "core",              // core | core_o2 | bgc
    region:               "greenland",         // greenland | denmark  -> which map
    status:               "active",            // active | inactive    -> marker colour
    status_note:          "",                  // why it is inactive ("" when active)
    latitude:             70.6154,
    longitude:            -18.3173,
    location:             "70.615° N, 18.317° W",
    deployment_date:      "2025-05-27",
    last_surface:         "2026-08-23 21:02",
    days_since:           0.9,
    next_surface:         "2026-08-28 20:02",  // "" when not predictable
    next_surface_source:  "nke cycle period",
    n_profiles:           94,                  // ascent profiles only
    track:                [[70.61, -18.32], /* ... */],
    trajectory:           "assets/plots/3902677/3902677_map.png",   // "" if none
    graphs: [
      { label: "Depth vs time",           src: "assets/plots/3902677/3902677_sections.png" },
      { label: "Profile 094 (2026-08-23)", src: "assets/plots/3902677/..." }
    ],
    notes: "sheet lists SBD+GDAC"
  }
];
```

`index.html` tolerates missing pieces: a float with no `trajectory` and no `graphs`
renders as "No figures available", and a region with no floats hides its whole map card.

## Sharing it as a single file

`bundle_single_file.py` folds `index.html`, `data.js` and every PNG into one
**`float_status.html`** (~13 MB) — the figures become base64 `data:` URIs and the data
becomes an inline `<script>`. There are no sibling folders to keep with it: mail it,
put it on OneDrive/Teams, or hand it over on a stick, and it opens by double-click.

Two things to know:

- **The libraries still load from the internet.** Leaflet/proj4 come from unpkg, and the
  Denmark panel's OSM tiles need a connection. The Greenland panel draws its own vector
  coastline and needs no tiles. Offline, the table, the fold-outs and every figure still
  work, and the map panels show a short "needs internet" note instead.
- **Figures are downscaled to 1600 px wide** where that actually shrinks the file. Use
  `--max-width 1200` for a smaller file, or `--max-width 0` to embed the originals.

| command | effect |
|---|---|
| `python bundle_single_file.py` | `float_status.html`, ~13 MB |
| `python bundle_single_file.py --max-width 1200` | ~10 MB |
| `python bundle_single_file.py --max-width 0` | full-resolution figures, largest |
| `python bundle_single_file.py --out somewhere/status.html` | write elsewhere |

Rebuild it after every data refresh — it is a snapshot, not a live view.

### Or share one *link* instead

The site is hosted — see *Hosting* below.

## Hosting

The site is published with **GitHub Pages** from a separate clone, so the working folder
on the Desktop stays the place you experiment and only finished work is pushed:

    working copy   Desktop\CLAUDE\Argo_float_data\float-site   <- edit + regenerate here
    publish clone  Documents\git_repos\float-site               <- git repo, pushed to GitHub
    live           https://bodil-bt.github.io/Danish_profiling_floats/

Full weekly cycle:

```bash
python make_plots.py
```

```bash
matlab -batch export_data
```

```bash
python publish.py
```

then review the diff in GitHub Desktop and Commit + Push. The live site updates within
about a minute.

**Use `publish.py` rather than copying the folder by hand.** The per-profile figures carry
the profile number and date in their *filename*
(`2903997_profile_039_2026-08-24.png`), so every refresh writes a NEW name. A plain
copy-over leaves the previous week's file behind, and the repo quietly fills with
orphaned PNGs that nothing on the page references. `publish.py` mirrors instead: it
copies what changed **and deletes what no longer exists**. It runs no git commands —
nothing is committed or pushed until you do it.

It leaves alone anything git ignores (`float_status.html`, `__pycache__`) and anything
that belongs to the clone (`.git`, `.gitattributes`). Check first with:

```bash
python publish.py --dry-run
```

Two things to keep in mind about Pages: the site is **public** (a private repo does not
give a private site outside Enterprise), and the repo grows by roughly **12 MB per
refresh** — about 0.6 GB of git history a year, against GitHub's 1 GB recommendation. The
`.gitignore` keeps the ~14 MB single-file build out of git for exactly that reason;
attach it to a Release instead if you want to distribute it. Squashing history or
publishing from a reset orphan branch are the options if the repo gets large.

## Dependencies

- **Python 3** with **PyMuPDF** (`pip install pymupdf`) — only needed to convert PDF
  figures. The current pipeline writes PNGs, which are copied directly; the PDF path
  exists because the pipeline used to emit PDFs and the GDAC add-on still does.
- **MATLAB** (tested on R2025a) for `export_data.m`. No toolboxes and no GSW needed —
  it only loads the already-derived `.mat` files.
- **Pillow** (`pip install pillow`) — only for `bundle_single_file.py`'s downscaling.
- **m_map** on the MATLAB path — only for `export_coastline.m`, and already required by
  the pipeline's own plots. Nothing is downloaded.
- **Leaflet 1.9.4**, **proj4 2.11** and **proj4leaflet 1.0.2** from unpkg.com, plus
  **OpenStreetMap** tiles for the Denmark panel. No API key. To make the page work fully
  offline apart from the Denmark tiles, download the three libraries into
  `assets/vendor/` and point the tags in `index.html` at them.

## Publishing

The folder is self-contained — copy `index.html`, `data.js` and `assets/` to any web
host or share the folder as-is. Check before publishing that the floats listed are ones
we are happy to share publicly, since `data.js` carries positions and the fold-outs
carry the figures.
