#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 EugenyH
"""Checks the locale files in src/eugenyh_step_import/locales.

- every locale parses and has "_language_name";
- every locale has exactly the keys of en.json and the same %{placeholders};
- every key used in main.rb (t('...')) or sent by step2stl_fc.py exists in en.json;
- keys in en.json that nothing uses are reported as warnings.

Usage: python tools/check_locales.py
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'src', 'eugenyh_step_import')
LOCALES = os.path.join(PKG, 'locales')
PLACEHOLDER = re.compile(r'%\{(\w+)\}')


def load(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def read(name):
    with open(os.path.join(PKG, name), encoding='utf-8') as f:
        return f.read()


def main():
    errors, warnings = [], []
    base = load(os.path.join(LOCALES, 'en.json'))
    base_keys = {k for k in base if not k.startswith('_')}

    for path in sorted(glob.glob(os.path.join(LOCALES, '*.json'))):
        code = os.path.basename(path)[:-5]
        try:
            data = load(path)
        except ValueError as e:
            errors.append('%s.json: invalid JSON: %s' % (code, e))
            continue
        if not data.get('_language_name'):
            errors.append('%s.json: missing "_language_name"' % code)
        keys = {k for k in data if not k.startswith('_')}
        for k in sorted(base_keys - keys):
            errors.append('%s.json: missing key %s' % (code, k))
        for k in sorted(keys - base_keys):
            errors.append('%s.json: unknown key %s' % (code, k))
        for k in sorted(keys & base_keys):
            if set(PLACEHOLDER.findall(data[k])) != set(PLACEHOLDER.findall(base[k])):
                errors.append('%s.json: placeholders of %s differ from en.json' % (code, k))

    used = set(re.findall(r"\bt\('([\w.]+)'", read('main.rb')))
    used |= set(re.findall(r"'((?:stage|detail)\.\w+)'", read('step2stl_fc.py')))
    for k in sorted(used - base_keys):
        errors.append('key used in code but missing from en.json: %s' % k)
    for k in sorted(base_keys - used):
        warnings.append('en.json key not found in code: %s' % k)

    for w in warnings:
        print('warning:', w)
    for e in errors:
        print('error:', e)
    if errors:
        sys.exit(1)
    print('Locales OK (%d keys, %d languages)' % (len(base_keys), len(glob.glob(os.path.join(LOCALES, '*.json')))))


if __name__ == '__main__':
    main()
