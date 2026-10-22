# STEP Import for SketchUp (via FreeCAD)

*Русская версия: [README.ru.md](README.ru.md)*

A SketchUp extension that imports **STEP assemblies** and keeps their structure:
parts become groups, repeated parts (screws, nuts…) become **components**, and
heavy sub-assemblies such as a populated PCB can be merged into a single mesh.
The result is saved next to the STEP file as a `.skp`.

SketchUp's Ruby API cannot read STEP (a B-Rep / NURBS format), so the extension
delegates the geometry to [FreeCAD](https://www.freecad.org/) running headless,
then rebuilds the model in SketchUp.

<!-- Add a screenshot: docs/screenshot.png, then uncomment:
![Imported assembly](docs/screenshot.png)
-->

## Features

- Assembly hierarchy preserved as nested groups
- Identical parts detected automatically → one component definition, many instances
- Big containers (default: 50+ parts) merged into one mesh, so a PCB with ~1200
  components imports in seconds instead of creating 1200 groups
- Native progress window: stage, current part, log, elapsed time, **Cancel**
- FreeCAD console window is hidden
- Result saved as `<name>.skp` next to the STEP file
- Progress log in `%TEMP%\step_import.log`

## How it works

```
STEP ──► FreeCADCmd + step2stl_fc.py ──► def_XXXX.stl + manifest.json
                                              │
              SketchUp (Ruby) ◄───────────────┘
              groups / components with placement matrices ──► .skp
```

1. FreeCAD opens the STEP, walks the assembly tree and tessellates each **unique** shape once.
2. Parts are compared by a position-independent fingerprint (solids, faces, edges,
   volume, area, bounding box of the local shape). Matches share one STL.
3. `manifest.json` records the hierarchy, the definitions and a 4×4 placement
   matrix for every instance.
4. The extension reads the STL files, creates groups / component definitions and
   places the instances with the matrices.

## Requirements

- **Windows** (the launcher and FreeCAD discovery are Windows-specific)
- **SketchUp 2021 or newer** (Ruby 2.7+). Developed and tested on SketchUp 2024.
- **FreeCAD** installed (`FreeCADCmd.exe`). Tested with: *FreeCAD version — fill in*.
  No separate Python is needed; the script runs inside FreeCAD's own interpreter.

## Installation

1. Download `eugenyh_step_import-<version>.rbz` from the [Releases](../../releases) page
   (or build it yourself, see below).
2. SketchUp: **Window → Extension Manager → Install Extension** and pick the `.rbz`.
3. Restart SketchUp.

On first run the extension looks for `C:\Program Files\FreeCAD*\bin\FreeCADCmd.exe`;
if it is not found you are asked to point to it, and the path is remembered.

## Usage

**Extensions → Import STEP assembly (FreeCAD)**, choose a `.step` / `.stp` file and
watch the progress window. When it finishes, the model is in SketchUp and a `.skp`
is saved next to the STEP file.

> Don't edit the model while the import is running: the model is built inside a
> single undoable operation, which is rolled back on cancel or error.

## Configuration

Constants at the top of `eugenyh_step_import/main.rb` (inside the installed
extension folder under `Plugins`):

| Constant | Default | Meaning |
|---|---|---|
| `TOL` | `'0.1'` | Tessellation tolerance for normal parts, mm |
| `TOL_MERGED` | `'0.5'` | Tolerance for merged containers, mm |
| `MERGE_MIN` | `'50'` | A container with at least this many parts is merged into one mesh |
| `SAVE_SKP` | `true` | Save `<name>.skp` next to the STEP file |
| `SOFTEN_ANGLE` | `10` | Edges between faces closer than this angle (°) are softened |
| `SOFTEN_MAX` | `20_000` | Skip edge softening for meshes larger than this (triangles) |
| `BIG_TRIS` | `300_000` | Ask for confirmation above this many triangles in one STL |
| `HIDE_FREECAD` | `true` | Hide the FreeCAD console window |
| `FREECAD_TIMEOUT` | `900` | Seconds before a stuck FreeCAD is killed |

## Limitations

- **Colors and materials are not imported.** `FreeCADCmd` has no GUI and does not
  read STEP colors; STL carries none.
- Units are assumed to be millimetres (FreeCAD's native unit).
- Assemblies built from `App::Link` objects may come out incomplete (links are skipped).
- If a part's geometry is baked into global coordinates instead of a placement,
  repeated copies are not recognised and come out as separate groups.
- SketchUp cannot represent edges shorter than 0.001″ (≈ 0.025 mm): the tiniest
  sliver triangles of dense meshes disappear (≈ 0.16 % of the area on a test PCB).
- Parts whose shapes differ by less than 0.01 mm may be treated as identical.
- The user interface is currently in **Russian only**.
- Windows only; not tested on other platforms.

## Troubleshooting

- Progress and errors are written to `%TEMP%\step_import.log` (readable while the import runs).
- On errors the temporary folder `%TEMP%\step2stl…` is kept: it contains the STL
  files, `manifest.json`, `freecad.log` and `error.txt`.
- If the FreeCAD window is visible, Windows Script Host is probably disabled; the
  extension then falls back to a normal launch.

## Performance notes for SketchUp extension developers

Findings from building this, measured on a ~160k-triangle PCB mesh:

- `Entities#add_faces_from_mesh` slows down superlinearly: 0.34 s for 5k triangles,
  4.3 s for 20k, 29 s for 40k. `Entities#fill_from_mesh(mesh, true, 0)` did 35k in 0.27 s —
  but it only fills an **empty** collection. Further calls into the same entities
  add nothing, so each mesh must be built in one call (one group/definition per mesh).
- `Geom::PolygonMesh#add_point` merges points closer than 0.001″, silently
  collapsing very small triangles.
- Building a very large `PolygonMesh` is itself superlinear; this is a fixed cost.
- The Ruby Console does not repaint while the main thread is busy — log to a file
  if you want to watch progress from outside.
- Console programs started from SketchUp open a visible console window on Windows.
  `wscript` + `WScript.Shell.Run … , 0` starts them hidden without FFI.

`tools/step_bench.rb` and `tools/step_check.rb` are the small scripts used for these
measurements (run them from the Ruby Console).

## Building from source

```
python build_rbz.py
```

produces `dist/eugenyh_step_import-<version>.rbz`. The `.rbz` is a ZIP archive with
the loader in the root; the script makes sure paths use forward slashes.

## License

[MIT](LICENSE)

This project is not affiliated with or endorsed by Trimble / SketchUp or the FreeCAD
project. FreeCAD is started as a separate process and is not bundled.
