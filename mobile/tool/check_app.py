"""Verify the packaged iOS asset location used by the Flutter isolate."""
import hashlib
import json
from pathlib import Path
import sys

app = Path(sys.argv[1])
repo = Path(__file__).resolve().parents[2]
assets = app / 'Frameworks/App.framework/flutter_assets/assets/stage2'
research = repo / 'research'
int8 = json.loads((research / 'models/e5-manifest.json').read_text())
fp32 = json.loads((research / 'models/e5-fp32-manifest.json').read_text())
head = (repo / 'mobile/assets/stage2/head.json').read_bytes()
for name, expected in {
    'model.onnx': fp32['files']['model.onnx']['sha256'],
    'tokenizer.json': int8['files']['tokenizer.json']['sha256'],
    'head.json': hashlib.sha256(head).hexdigest(),
}.items():
    checksum = hashlib.sha256()
    with (assets / name).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    if expected != checksum.hexdigest():
        raise SystemExit(f'Wrong bytes in app: {name}')
    print(f'{name}: verified in Runner.app')
print('App bytes:', sum(p.stat().st_size for p in app.rglob('*') if p.is_file()))
