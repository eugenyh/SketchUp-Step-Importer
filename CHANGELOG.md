# Changelog

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
