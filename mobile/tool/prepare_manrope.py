"""Prepare four offline static Manrope faces from pinned Google Fonts sources.

Requires fonttools==4.61.1 only on the asset-preparation machine, not in the app.
Run: python mobile/tool/prepare_manrope.py [--fonttools-path TEMP_DIRECTORY]
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
import urllib.request

COMMIT = 'b31870aff700ab7a1d74fa0c6887d95beb9e0037'
BASE = f'https://raw.githubusercontent.com/google/fonts/{COMMIT}/ofl/manrope/'
WEIGHTS = {'Light': 300, 'Regular': 400, 'Medium': 500, 'SemiBold': 600}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--fonttools-path')
    args = parser.parse_args()
    if args.fonttools_path:
        sys.path.insert(0, args.fonttools_path)
    import fontTools
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    target = Path(__file__).resolve().parents[1] / 'assets' / 'fonts'
    target.mkdir(parents=True, exist_ok=True)
    sources = {}
    for remote, local in [('Manrope%5Bwght%5D.ttf', 'Manrope-Variable.source.ttf'),
                          ('OFL.txt', 'OFL.txt'), ('METADATA.pb', 'upstream-METADATA.pb')]:
        with urllib.request.urlopen(BASE + remote, timeout=30) as response:
            content = response.read()
        (target / local).write_bytes(content)
        sources[local] = {'url': BASE + remote, 'sha256': hashlib.sha256(content).hexdigest(),
                          'bytes': len(content)}
    variable = (target / 'Manrope-Variable.source.ttf').read_bytes()
    faces = {}
    required = set(map(ord, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
        'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя0123456789'))
    for label, weight in WEIGHTS.items():
        font = TTFont(io.BytesIO(variable), recalcTimestamp=False)
        face = instantiateVariableFont(font, {'wght': weight}, inplace=False, updateFontNames=True)
        assert 'fvar' not in face
        assert required <= set(face.getBestCmap())
        assert face['OS/2'].usWeightClass == weight
        path = target / f'Manrope-{label}.ttf'
        face.save(path)
        content = path.read_bytes()
        faces[path.name] = {'weight': weight, 'sha256': hashlib.sha256(content).hexdigest(),
                            'bytes': len(content), 'russian_latin_digits_verified': True}
    manifest = {'family': 'Manrope', 'license': 'SIL Open Font License 1.1',
                'google_fonts_commit': COMMIT, 'fonttools_version': fontTools.__version__,
                'source_files': sources, 'static_faces': faces,
                'runtime_network': False, 'generation': 'wght static instancing; no glyph subsetting'}
    (target / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'source_commit': COMMIT, 'faces': faces}, indent=2))


if __name__ == '__main__':
    main()
