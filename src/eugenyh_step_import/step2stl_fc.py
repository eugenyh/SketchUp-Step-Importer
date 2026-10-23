# -*- coding: utf-8 -*-
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
"""STEP -> STL converter for the SketchUp plugin (runs under FreeCADCmd).

Parameters come from environment variables:
  STEP_IN, OUT_DIR, STEP_TOL, STEP_TOL_MERGED, MERGE_MIN

Service files in OUT_DIR (read by the plugin):
  pid.txt        - PID of this process (so the plugin can kill it)
  progress.json  - {"fraction": 0..1 | null, "stage": "<key>", "detail": "<key>" | "", "args": {...}}
                   stage/detail are translation keys from locales/*.json; the plugin
                   translates them, so this script contains no user-facing text.
  done.flag      - created last, when manifest.json is complete
  error.txt      - traceback on failure
  freecad.log    - output of this script
"""
import os
import sys
import json
import time
import traceback

SRC = os.environ['STEP_IN']
OUT = os.environ['OUT_DIR']
TOL = float(os.environ.get('STEP_TOL', '0.1'))                        # mm
TOL_MERGED = float(os.environ.get('STEP_TOL_MERGED', str(TOL * 2)))   # mm, for merged containers
MERGE_MIN = int(os.environ.get('MERGE_MIN', '50'))

_log = open(os.path.join(OUT, 'freecad.log'), 'w', buffering=1, encoding='utf-8')
sys.stdout = _log
sys.stderr = _log


def write_text(name, text):
    with open(os.path.join(OUT, name), 'w', encoding='utf-8') as f:
        f.write(text)


write_text('pid.txt', str(os.getpid()))

_last_report = [0.0]


def report(fraction, stage, detail='', args=None, force=False):
    """Atomically updates progress.json (at most 4 times a second unless force)."""
    now = time.time()
    if not force and now - _last_report[0] < 0.25:
        return
    _last_report[0] = now
    path = os.path.join(OUT, 'progress.json')
    tmp = path + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'fraction': fraction, 'stage': stage, 'detail': detail,
                       'args': args or {}}, f)
        os.replace(tmp, path)
    except OSError:
        pass          # the file may be open in the plugin at this moment, not a problem


def main():
    report(None, 'stage.reading_step', 'detail.reading_step', force=True)

    import FreeCAD
    import Part
    import Import
    import MeshPart

    doc = FreeCAD.newDocument('asm')
    Import.insert(SRC, doc.Name)
    doc.recompute()
    print('STEP loaded, objects: %d' % len(doc.Objects))

    defs = {}          # fingerprint -> definition index
    defs_list = []     # unique shapes
    instances = []     # all instances
    IDENT = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    def is_container(o):
        return bool(getattr(o, 'Group', None))

    def leaves(o):
        """All leaf parts with geometry inside the object."""
        if is_container(o):
            res = []
            for k in o.Group:
                res += leaves(k)
            return res
        if o.isDerivedFrom('Part::Feature') and not o.Shape.isNull() and o.Shape.Faces:
            return [o]
        return []

    def weight(o):
        try:
            return 1 + len(o.Shape.Faces)
        except Exception:
            return 1

    def should_merge(o):
        if len(leaves(o)) < MERGE_MIN:
            return False
        for k in o.Group:             # do not merge if it holds its own big container
            if is_container(k) and len(leaves(k)) >= MERGE_MIN:
                return False
        return True

    def fingerprint(s):
        bb = s.BoundBox
        vals = (s.Volume, s.Area, bb.XMin, bb.YMin, bb.ZMin,
                bb.XMax, bb.YMax, bb.ZMax)
        return (len(s.Solids), len(s.Faces), len(s.Edges)) + tuple(round(v, 2) for v in vals)

    def global_pl(o):
        try:
            return o.getGlobalPlacement()
        except Exception:
            return o.Placement

    # Total work: number of faces over all parts (rough time estimate)
    report(0.10, 'stage.analyzing', force=True)
    total = 0
    for root in doc.RootObjects:
        for lf in leaves(root):
            total += weight(lf)
    total = max(total, 1)
    print('Leaf parts: %d, weight %d' % (sum(len(leaves(r)) for r in doc.RootObjects), total))

    state = {'done': 0}

    def progress(detail='', args=None, stage='stage.tessellating', force=False):
        frac = 0.12 + 0.85 * min(state['done'] / float(total), 1.0)
        report(frac, stage, detail, args, force)

    def add_merged(obj, path):
        shapes = []
        w = 0
        for lf in leaves(obj):
            s = lf.Shape.copy()
            s.Placement = global_pl(lf)          # part goes straight into global coordinates
            shapes.append(s)
            w += weight(lf)
        name = obj.Label or ('Merged_%d' % len(defs_list))
        progress('detail.merging', {'name': name, 'count': len(shapes)},
                 'stage.tessellating_big', force=True)
        comp = Part.makeCompound(shapes)
        did = len(defs_list)
        fname = 'def_%04d.stl' % did
        mesh = MeshPart.meshFromShape(Shape=comp, LinearDeflection=TOL_MERGED,
                                      AngularDeflection=0.5, Relative=False)
        mesh.write(os.path.join(OUT, fname))
        defs_list.append({'file': fname, 'name': name, 'count': 1})
        instances.append({'def': did, 'name': name, 'path': path, 'matrix': IDENT})
        state['done'] += w
        print('MERGED: %s (%d parts)' % (name, len(shapes)))
        progress('detail.part', {'name': name}, force=True)

    def walk(obj, path):
        if is_container(obj):
            if should_merge(obj):
                add_merged(obj, path)
                return
            for ch in obj.Group:
                walk(ch, path + [obj.Label])
            return
        if not obj.isDerivedFrom('Part::Feature'):
            return
        shape = obj.Shape.copy()
        if shape.isNull() or not shape.Faces:
            return
        w = weight(obj)
        gp = global_pl(obj)
        shape.Placement = FreeCAD.Placement()
        key = fingerprint(shape)

        if key not in defs:
            progress('detail.part', {'name': obj.Label or ''}, force=True)
            did = len(defs_list)
            fname = 'def_%04d.stl' % did
            mesh = MeshPart.meshFromShape(Shape=shape, LinearDeflection=TOL,
                                          AngularDeflection=0.5, Relative=False)
            mesh.write(os.path.join(OUT, fname))
            defs[key] = did
            defs_list.append({'file': fname, 'name': obj.Label or ('Part_%d' % did),
                              'count': 0})

        did = defs[key]
        defs_list[did]['count'] += 1
        m = gp.toMatrix()
        instances.append({
            'def': did,
            'name': obj.Label or ('Part_%d' % did),
            'path': path,
            'matrix': [m.A11, m.A12, m.A13, m.A14,
                       m.A21, m.A22, m.A23, m.A24,
                       m.A31, m.A32, m.A33, m.A34,
                       m.A41, m.A42, m.A43, m.A44],
        })
        state['done'] += w
        progress('detail.part', {'name': obj.Label or ''})

    for root in doc.RootObjects:
        walk(root, [])

    report(0.98, 'stage.writing', 'detail.written',
           {'defs': len(defs_list), 'insts': len(instances)}, force=True)
    with open(os.path.join(OUT, 'manifest.json'), 'w') as f:
        json.dump({'definitions': defs_list, 'instances': instances}, f)

    report(1.0, 'stage.fc_finished', force=True)
    print('definitions: %d, instances: %d' % (len(defs_list), len(instances)))


try:
    main()
    write_text('done.flag', 'ok')       # created strictly after manifest.json
except BaseException:
    write_text('error.txt', traceback.format_exc())

_log.flush()
sys.exit(0)
