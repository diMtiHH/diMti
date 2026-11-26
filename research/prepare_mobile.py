"""Restore the pinned iPhone bundle. Only the build machine needs Internet."""
import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path

from .fetch_e5 import ROOT, download, verify_file

ASSETS = ROOT.parent / 'mobile/assets/stage2'
HEAD_SHA256 = 'fc3593cfabdc324d4e37b69c4fd49749e957bb582e42367fcbcb7692feab8ea9'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Use only verified local files')
    args = parser.parse_args()
    head = (ASSETS / 'head.json').read_bytes()
    if hashlib.sha256(head).hexdigest() != HEAD_SHA256:
        raise ValueError('Bundled classifier checksum mismatch')
    revision = json.loads(head)['encoder_revision']
    for manifest_file, name in [('e5-fp32-manifest.json', 'model.onnx'),
                                ('e5-manifest.json', 'tokenizer.json')]:
        manifest = json.loads((ROOT / 'models' / manifest_file).read_text())
        spec = manifest['files'][name]
        if manifest['revision'] != revision:
            raise ValueError('Incompatible encoder revision')
        destination = ASSETS / name
        if not destination.exists():
            cached = ROOT / 'artifacts/e5-small' / name
            if cached.exists() or args.offline:
                verify_file(cached, spec)
                fd, filename = tempfile.mkstemp(dir=ASSETS, prefix='.prepare-')
                try:
                    with os.fdopen(fd, 'wb') as target, cached.open('rb') as source:
                        shutil.copyfileobj(source, target)
                    verify_file(Path(filename), spec)
                    os.replace(filename, destination)
                finally:
                    Path(filename).unlink(missing_ok=True)
            else:
                url = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{spec['path']}"
                download(url, destination, spec)
        verify_file(destination, spec)
        print(f'{name}: verified ({spec["size"]} bytes)')


if __name__ == '__main__':
    main()
