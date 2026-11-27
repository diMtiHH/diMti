"""Prepare offline RU/EN typography from pinned official Google Fonts sources.

Asset preparation only: fonttools==4.61.1; never needed by CI or the app.
Run with --fonttools-path if fontTools is installed in a temporary directory.
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
FAMILIES = (
    ('Cormorant Garamond', 'CormorantGaramond', 'cormorantgaramond',
     'CormorantGaramond%5Bwght%5D.ttf', 'headings', {},
     {'Light': 300, 'Regular': 400, 'Medium': 500, 'SemiBold': 600}),
    ('Literata', 'Literata', 'literata', 'Literata%5Bopsz,wght%5D.ttf',
     'body', {'opsz': 14}, {'Regular': 400, 'Medium': 500, 'SemiBold': 600}),
    ('Manrope', 'Manrope', 'manrope', 'Manrope%5Bwght%5D.ttf',
     'settings body and controls', {}, {'Regular': 400, 'Medium': 500}),
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--fonttools-path')
    args = parser.parse_args()
    if args.fonttools_path:
        sys.path.insert(0, args.fonttools_path)
    import fontTools
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont
    assert fontTools.__version__ == '4.61.1', 'Use the pinned preparation version'
    target = Path(__file__).resolve().parents[1] / 'assets/fonts'
    required = set(map(ord, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
        'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя'
        '0123456789.,:;!?—«»()'))
    families = []
    for family, prefix, folder, remote_font, role, axes, weights in FAMILIES:
        base = f'https://raw.githubusercontent.com/google/fonts/{COMMIT}/ofl/{folder}/'
        sources, faces = {}, {}
        license_name = 'OFL.txt' if family == 'Manrope' else f'{prefix}-OFL.txt'
        metadata_name = 'upstream-METADATA.pb' if family == 'Manrope' else f'{prefix}-upstream-METADATA.pb'
        for remote, local in ((remote_font, f'{prefix}-Variable.source.ttf'),
                              ('OFL.txt', license_name),
                              ('METADATA.pb', metadata_name)):
            with urllib.request.urlopen(base + remote, timeout=30) as response:
                content = response.read()
            (target / local).write_bytes(content)
            sources[local] = {'url': base + remote, 'sha256': hashlib.sha256(content).hexdigest(),
                              'bytes': len(content)}
        license_text = (target / license_name).read_text(encoding='utf-8')
        assert 'SIL OPEN FONT LICENSE Version 1.1' in license_text
        variable = (target / f'{prefix}-Variable.source.ttf').read_bytes()
        for label, weight in weights.items():
            font = TTFont(io.BytesIO(variable), recalcTimestamp=False)
            face = instantiateVariableFont(font, {**axes, 'wght': weight},
                                           inplace=False, updateFontNames=not axes)
            if axes:
                # Literata's STAT table only names some optical sizes. Keep a
                # readable UI size of 14 and name these static instances directly.
                names = {1: family, 2: label, 4: f'{family} {label}',
                         6: f'{prefix}-{label}', 16: family, 17: label}
                for record in list(face['name'].names):
                    if record.nameID in names:
                        face['name'].setName(names[record.nameID], record.nameID,
                                             record.platformID, record.platEncID, record.langID)
            assert 'fvar' not in face
            assert required <= set(face.getBestCmap()), family
            assert face['OS/2'].usWeightClass == weight
            path = target / f'{prefix}-{label}.ttf'
            face.save(path)
            content = path.read_bytes()
            faces[path.name] = {'weight': weight, 'sha256': hashlib.sha256(content).hexdigest(),
                               'bytes': len(content), 'russian_latin_digits_verified': True}
        families.append({'family': family, 'role': role, 'license': 'SIL Open Font License 1.1',
                         'license_file': license_name, 'fixed_axes': axes,
                         'source_files': sources, 'static_faces': faces})
    manifest = {'protocol': 'aura-offline-typography-v2', 'google_fonts_commit': COMMIT,
                'fonttools_version': fontTools.__version__, 'families': families,
                'runtime_network': False, 'generation': 'static instancing; no glyph subsetting'}
    (target / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'source_commit': COMMIT,
                      'families': [{'name': f['family'], 'faces': len(f['static_faces']),
                                    'bytes': sum(x['bytes'] for x in f['static_faces'].values())}
                                   for f in families]}, indent=2))


if __name__ == '__main__':
    main()
