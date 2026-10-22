# -*- coding: utf-8 -*-
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
"""Конвертер STEP -> STL для плагина SketchUp (запускается через FreeCADCmd).

Параметры приходят через переменные окружения:
  STEP_IN, OUT_DIR, STEP_TOL, STEP_TOL_MERGED, MERGE_MIN

Служебные файлы в OUT_DIR (их читает плагин):
  pid.txt        - PID процесса (чтобы плагин мог его завершить)
  progress.json  - {"fraction": 0..1 | null, "stage": "...", "detail": "..."}
  done.flag      - создаётся последним, когда manifest.json готов
  error.txt      - трассировка при ошибке
  freecad.log    - вывод скрипта
"""
import os
import sys
import json
import time
import traceback

SRC = os.environ['STEP_IN']
OUT = os.environ['OUT_DIR']
TOL = float(os.environ.get('STEP_TOL', '0.1'))                        # мм
TOL_MERGED = float(os.environ.get('STEP_TOL_MERGED', str(TOL * 2)))   # мм, для склеенных контейнеров
MERGE_MIN = int(os.environ.get('MERGE_MIN', '50'))

_log = open(os.path.join(OUT, 'freecad.log'), 'w', buffering=1, encoding='utf-8')
sys.stdout = _log
sys.stderr = _log


def write_text(name, text):
    with open(os.path.join(OUT, name), 'w', encoding='utf-8') as f:
        f.write(text)


write_text('pid.txt', str(os.getpid()))

_last_report = [0.0]


def report(fraction, stage, detail='', force=False):
    """Атомарно обновляет progress.json (не чаще 4 раз в секунду, если не force)."""
    now = time.time()
    if not force and now - _last_report[0] < 0.25:
        return
    _last_report[0] = now
    path = os.path.join(OUT, 'progress.json')
    tmp = path + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'fraction': fraction, 'stage': stage, 'detail': detail}, f)
        os.replace(tmp, path)
    except OSError:
        pass          # файл может быть открыт плагином в этот момент, не страшно


def main():
    report(None, 'Чтение STEP', 'FreeCAD загружает файл', force=True)

    import FreeCAD
    import Part
    import Import
    import MeshPart

    doc = FreeCAD.newDocument('asm')
    Import.insert(SRC, doc.Name)
    doc.recompute()
    print('STEP загружен, объектов: %d' % len(doc.Objects))

    defs = {}          # отпечаток -> индекс определения
    defs_list = []     # уникальные формы
    instances = []     # все вхождения
    IDENT = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    def is_container(o):
        return bool(getattr(o, 'Group', None))

    def leaves(o):
        """Все листовые детали с геометрией внутри объекта."""
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
        for k in o.Group:             # не склеиваем, если внутри есть свой крупный контейнер
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

    # Общий вес работы: число граней по всем деталям (грубая оценка времени)
    report(0.10, 'Анализ структуры сборки', '', force=True)
    total = 0
    for root in doc.RootObjects:
        for lf in leaves(root):
            total += weight(lf)
    total = max(total, 1)
    print('Деталей-листьев: %d, вес %d' % (sum(len(leaves(r)) for r in doc.RootObjects), total))

    state = {'done': 0}

    def progress(detail, stage='Триангуляция деталей', force=False):
        frac = 0.12 + 0.85 * min(state['done'] / float(total), 1.0)
        report(frac, stage, detail, force)

    def add_merged(obj, path):
        shapes = []
        w = 0
        for lf in leaves(obj):
            s = lf.Shape.copy()
            s.Placement = global_pl(lf)          # деталь сразу в глобальных координатах
            shapes.append(s)
            w += weight(lf)
        name = obj.Label or ('Merged_%d' % len(defs_list))
        progress('%s: склейка %d деталей в один меш' % (name, len(shapes)),
                 'Триангуляция (крупный узел)', force=True)
        comp = Part.makeCompound(shapes)
        did = len(defs_list)
        fname = 'def_%04d.stl' % did
        mesh = MeshPart.meshFromShape(Shape=comp, LinearDeflection=TOL_MERGED,
                                      AngularDeflection=0.5, Relative=False)
        mesh.write(os.path.join(OUT, fname))
        defs_list.append({'file': fname, 'name': name, 'count': 1})
        instances.append({'def': did, 'name': name, 'path': path, 'matrix': IDENT})
        state['done'] += w
        print('MERGED: %s (%d деталей)' % (name, len(shapes)))
        progress(name, force=True)

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
            progress(obj.Label or '', force=True)
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
        progress(obj.Label or '')

    for root in doc.RootObjects:
        walk(root, [])

    report(0.98, 'Запись результата', '%d форм, %d вхождений' % (len(defs_list), len(instances)), force=True)
    with open(os.path.join(OUT, 'manifest.json'), 'w') as f:
        json.dump({'definitions': defs_list, 'instances': instances}, f)

    report(1.0, 'FreeCAD завершил работу', '', force=True)
    print('definitions: %d, instances: %d' % (len(defs_list), len(instances)))


try:
    main()
    write_text('done.flag', 'ok')       # создаётся строго после manifest.json
except BaseException:
    write_text('error.txt', traceback.format_exc())

_log.flush()
sys.exit(0)
