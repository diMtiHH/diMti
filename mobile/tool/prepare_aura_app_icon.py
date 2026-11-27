"""Export opaque iOS icon sizes from the project's original Flutter vector mark.

First run `flutter test test/aura_ui_test.dart` to render the 1024px source.
Pillow is an offline preparation dependency only, never an app dependency.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--pillow-path', type=Path)
args = parser.parse_args()
if args.pillow_path:
    sys.path.insert(0, str(args.pillow_path))
from PIL import Image, __version__ as pillow_version

mobile = Path(__file__).resolve().parents[1]
source = mobile / 'build/stage6/aura-brand-candidate.png'
destination = mobile / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
catalog = json.loads((destination / 'Contents.json').read_text(encoding='utf-8'))
image = Image.open(source).convert('RGBA')
assert image.size == (1024, 1024)
assert image.getchannel('A').getextrema() == (255, 255), 'Source must be fully opaque'
image = image.convert('RGB')
exports = {}
for item in catalog['images']:
    name = item['filename']
    size = int(float(item['size'].split('x')[0]) * float(item['scale'].removesuffix('x')))
    if name in exports:
        continue
    output = destination / name
    image.resize((size, size), Image.Resampling.LANCZOS).save(output, format='PNG', optimize=False)
    with Image.open(output) as result:
        assert result.mode == 'RGB' and result.size == (size, size)
    data = output.read_bytes()
    exports[name] = {'size_px': size, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

identity = mobile / 'assets/identity'
identity.mkdir(parents=True, exist_ok=True)
manifest = {
    'protocol': 'aura13-original-vector-icon-v1',
    'origin': 'Original four-ray energy mark drawn by AuraIconPainter; no external image or font glyph',
    'vector_source': 'mobile/lib/aura_ui.dart',
    'vector_source_sha256': hashlib.sha256((mobile / 'lib/aura_ui.dart').read_bytes()).hexdigest(),
    'composition_source': 'mobile/test/aura_ui_test.dart',
    'source_render_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'export_script': 'mobile/tool/prepare_aura_app_icon.py',
    'pillow_version': pillow_version,
    'color_mode': 'RGB',
    'transparency': False,
    'final_brand_acceptance': False,
    'exports': exports,
}
(identity / 'app-icon-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(f'Exported {len(exports)} opaque original AURA icons; manifest: {identity / "app-icon-manifest.json"}')
