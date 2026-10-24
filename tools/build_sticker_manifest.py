#!/usr/bin/env python3
"""Rebuild static/stickers/manifest.json from the files in static/stickers/.

Run from the project root after adding or removing stickers:

    python3 tools/build_sticker_manifest.py

Any file ending in .webp or .png is a sticker, whatever its name (spaces,
capitals, unicode and extra dots are fine). Stickers have no categories.
Skipped with a warning: names starting with "." or a space, names containing
[ ] / backslash or control characters, and names longer than 120 characters before
the extension.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STICKER_DIR = os.path.join(ROOT, 'static', 'stickers')
EXTS = ('.png', '.webp')
# Keep in sync with CHAT_STICKER_FILE_RE in static/js/chat-gif.js.
NAME_RE = re.compile(r'^[^\s.\[\]/\\\x00-\x1f][^\[\]/\\\x00-\x1f]{0,119}\.(?:png|webp)$', re.IGNORECASE)


def main():
    os.makedirs(STICKER_DIR, exist_ok=True)
    files = sorted(f for f in os.listdir(STICKER_DIR) if f.lower().endswith(EXTS))
    good = []
    for f in files:
        if NAME_RE.match(f):
            good.append(f)
        else:
            print('skipped (unusable name): ' + f, file=sys.stderr)
    with open(os.path.join(STICKER_DIR, 'manifest.json'), 'w', encoding='utf-8') as fh:
        json.dump({'stickers': good}, fh, indent=2, ensure_ascii=False)
        fh.write('\n')
    print('stickers manifest.json: %d sticker(s)' % len(good))


if __name__ == '__main__':
    main()
