#!/usr/bin/env python3
"""
Packs tools/skinsss/pk3/ (shader overrides + masks from make_masks.ps1) into
zz_skinsss_test.pk3 next to this script. It is not installed anywhere: copy it
into the game's base/ for the r_skinSSS test characters, remove it to go back.

usage: make_pk3.py
"""

import os
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, 'pk3')
out = os.path.join(here, 'zz_skinsss_test.pk3')

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            path = os.path.join(dirpath, f)
            arc = os.path.relpath(path, root).replace(os.sep, '/')
            z.write(path, arc)
            print(arc)
print('->', out)
