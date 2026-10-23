#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
"""Packs src/ into dist/eugenyh_step_import-<version>.rbz.

An .rbz is a plain ZIP archive. Entries must use forward slashes and the
extension loader (eugenyh_step_import.rb) must sit in the archive root,
which is why the archive is built here instead of with a generic zip tool.

Usage:
    python build_rbz.py             # build the package
    python build_rbz.py --version   # print the extension version
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'src')
DIST = os.path.join(ROOT, 'dist')
LOADER = 'eugenyh_step_import.rb'
REQUIRED = [LOADER,
            'eugenyh_step_import/main.rb',
            'eugenyh_step_import/i18n.rb',
            'eugenyh_step_import/settings.rb',
            'eugenyh_step_import/step2stl_fc.py',
            'eugenyh_step_import/locales/en.json']


def read_version():
    with open(os.path.join(SRC, LOADER), encoding='utf-8') as f:
        m = re.search(r"ex\.version\s*=\s*'([^']+)'", f.read())
    if not m:
        sys.exit('Cannot find ex.version in %s' % LOADER)
    return m.group(1)


def collect():
    files = []
    for base, dirs, names in os.walk(SRC):
        dirs[:] = sorted(d for d in dirs if d != '__pycache__')
        for name in sorted(names):
            if name.endswith(('.pyc', '.rbz')):
                continue
            full = os.path.join(base, name)
            files.append((full, os.path.relpath(full, SRC).replace(os.sep, '/')))
    files.sort(key=lambda p: (p[1] != LOADER, p[1]))     # loader first
    return files


def main():
    version = read_version()
    if '--version' in sys.argv:
        print(version)
        return

    files = collect()
    arcnames = [a for _, a in files]
    missing = [r for r in REQUIRED if r not in arcnames]
    if missing:
        sys.exit('Missing files in src/: %s' % ', '.join(missing))

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'eugenyh_step_import-%s.rbz' % version)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full, arc in files:
            z.write(full, arc)

    print('Built %s' % out)
    for arc in arcnames:
        print('  ' + arc)


if __name__ == '__main__':
    main()
