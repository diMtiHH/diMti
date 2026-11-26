"""Download pinned public artifacts with TLS, length and publisher SHA-256 checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent


class HTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('HTTPS redirect required')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_https(url):
    return urllib.request.build_opener(HTTPSRedirectHandler()).open(url, timeout=60)


def verify_file(path, spec):
    if path.stat().st_size != spec['size']:
        raise ValueError('Artifact length mismatch')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != spec['sha256']:
        raise ValueError('Artifact checksum mismatch')


def download(url, destination, spec):
    if not url.startswith('https://'):
        raise ValueError('HTTPS required')
    if destination.exists():
        verify_file(destination, spec)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.download-',dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd,'wb') as target:
            with open_https(url) as response:
                if not response.url.startswith('https://'):
                    raise ValueError('HTTPS redirect required')
                received = 0
                while block := response.read(1024*1024):
                    received += len(block)
                    if received > spec['size']:
                        raise ValueError('Artifact larger than expected')
                    target.write(block)
        verify_file(temporary,spec)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fp32',action='store_true',help='Fetch optional verified FP32 reference graph')
    args=parser.parse_args()
    manifest_name='e5-fp32-manifest.json' if args.fp32 else 'e5-manifest.json'
    manifest=json.loads((ROOT/'models'/manifest_name).read_text())
    destination=ROOT/'artifacts/e5-small'
    for name,spec in manifest['files'].items():
        url=f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{spec['path']}"
        try:
            download(url,destination/name,spec)
        except Exception as exc:
            # Redirect URLs may carry signed parameters. Never print the exception URL.
            print(f'{name}: download not verified ({type(exc).__name__}); no model readiness claim')
            return 1
        print(f'{name}: verified')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
