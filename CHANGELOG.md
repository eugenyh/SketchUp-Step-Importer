# Changelog

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
