#!/usr/bin/env python3
"""Rebuild static/gifs/manifest.json from the GIF files in static/gifs/.

Run from the project root after adding or removing GIFs:

    python3 tools/build_gif_manifest.py

File names must be <category>_<name>.gif or <name>.gif: lowercase letters,
digits and hyphens, with at most one underscore (between category and name).
Files that break the convention are skipped with a warning.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GIF_DIR = os.path.join(ROOT, 'static', 'gifs')
NAME_RE = re.compile(r'^[a-z0-9][a-z0-9-]*(?:_[a-z0-9][a-z0-9-]*)?\.gif$')


def main():
    files = sorted(f for f in os.listdir(GIF_DIR) if f.lower().endswith('.gif'))
    good = []
    for f in files:
        if NAME_RE.match(f):
            good.append(f)
        else:
            print('skipped (bad name): ' + f, file=sys.stderr)
    with open(os.path.join(GIF_DIR, 'manifest.json'), 'w', encoding='utf-8') as fh:
        json.dump({'gifs': good}, fh, indent=2)
        fh.write('\n')
    print('manifest.json: %d GIF(s)' % len(good))


if __name__ == '__main__':
    main()
