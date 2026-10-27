# Changelog

## 1.3.1

- Face merging now also covers big meshes: `MERGE_MAX` raised from 60 000 to 200 000 triangles
  (a 161k-triangle PCB mesh merges in about 4 s).

## 1.3.0

- Tiny faces are no longer lost. SketchUp silently refused to build faces from very small
  triangles (on a test part 132 of 2488 became edges without faces, leaving open holes).
  Geometry is now built `BUILD_SCALE` (10) times larger and each instance carries the inverse
  scale, so the model keeps its real size. Set `BUILD_SCALE = 1` for the old behaviour.
  Instances therefore show a scale of 1/10 in Entity Info; exploding them scales the geometry
  back down and may drop tiny faces again.

## 1.2.0

- Coplanar triangles from STL are merged into polygons after import (`MERGE_COPLANAR`,
  skipped for meshes above `MERGE_MAX` triangles). On a test part this roughly halves the
  face count, so a separate cleanup pass is no longer needed for this.

## 1.1.0

- **English is now the primary interface language.** Russian is available as a second language;
  all user-facing text lives in `locales/<code>.json`, so more languages can be added without
  touching the code (see "Adding a language" in the README).
- New **Settings** dialog (*Extensions → STEP Import (FreeCAD) → Settings…*): interface language
  and the path to `FreeCADCmd.exe` (Browse / Auto-detect; empty = detect automatically).
- Settings are stored in `%APPDATA%\EugenyH\StepImport\settings.json`. A path saved by earlier
  versions in the Windows registry is migrated automatically.
- FreeCADCmd auto-detection now also looks in `Program Files` on other drives and in
  `%LOCALAPPDATA%\Programs`.
- The menu is now a submenu: *Import STEP assembly…* and *Settings…*.
- `step2stl_fc.py` reports progress as translation keys instead of Russian text.
- The work log (`%TEMP%\step_import.log`) is always written in English.
- CI: new `tools/check_locales.py` verifies that all locales have the same keys and placeholders
  as `en.json` and that every key used in the code exists.

## 1.0.0 — first public release

- Imports STEP assemblies through FreeCAD (`FreeCADCmd.exe`) and builds the model in SketchUp.
- Assembly hierarchy is preserved as nested groups.
- Identical parts are detected by a position-independent fingerprint and become one
  component definition with many instances (fasteners, standard parts).
- Large containers (default: 50+ parts, e.g. a populated PCB) are merged into a single mesh.
- The result is saved next to the STEP file as `<name>.skp`.
- Native progress window (HtmlDialog) with stage, current part, log, elapsed time and Cancel.
- FreeCAD runs hidden (via `wscript`); falls back to a normal launch if Windows Script Host is unavailable.
- Progress log in `%TEMP%\step_import.log`; the temp folder is kept on errors for diagnosis.
