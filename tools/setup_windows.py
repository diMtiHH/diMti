"""Install the Windows x64 tools and exercise the project's local model."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / 'mobile'
VERSION = '3.50.1'
REVISION = 'ae9b586f34a8443573f82ef57c3bf914a908cbf7'
SDK_URL = f'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_{VERSION}-stable.zip'
SDK_SHA256 = '33c1e3d4dd08f1136ddb9c7976cfd2b0ab20296f1565b78ba176a4cbb4e140eb'


def run(*args, cwd=ROOT):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def install_package(package):
    if not shutil.which('winget.exe'):
        raise RuntimeError(f'Microsoft App Installer with WinGet is required to install {package}.')
    run('winget.exe', 'install', '--exact', '--id', package, '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements')


def find_git():
    candidates = [shutil.which('git.exe'),
                  Path(os.environ.get('ProgramW6432', os.environ['ProgramFiles'])) / 'Git/cmd/git.exe',
                  Path(os.environ['LOCALAPPDATA']) / 'Programs/Git/cmd/git.exe']
    return next((Path(p) for p in candidates if p and Path(p).is_file()), None)


def expected_sdk(path):
    if not (path / 'bin/flutter.bat').is_file() or not (path / '.git').exists():
        return False
    ref = subprocess.run(['git.exe', '-C', str(path), 'rev-parse', 'HEAD'],
                         capture_output=True, text=True)
    return ref.returncode == 0 and ref.stdout.strip() == REVISION


def flutter_sdk():
    existing = shutil.which('flutter.bat')
    if existing and expected_sdk(Path(existing).resolve().parents[1]):
        return Path(existing)
    folder = Path(os.environ['LOCALAPPDATA']) / 'AskTheUniverse'
    target = folder / f'flutter-{VERSION}'
    if not expected_sdk(target):
        if target.exists():
            raise RuntimeError(f'Unexpected SDK at {target}. Move it aside and retry.')
        folder.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='sdk-', dir=folder) as staging:
            staging = Path(staging)
            archive = staging / 'flutter.zip'
            print(f'Downloading Flutter {VERSION} for Windows x64.', flush=True)
            run('curl.exe', '--fail', '--location', '--retry', '3', '--output', archive, SDK_URL)
            digest = hashlib.sha256()
            with archive.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            if digest.hexdigest() != SDK_SHA256:
                raise RuntimeError('Flutter archive checksum mismatch.')
            run('tar.exe', '-xf', archive, '-C', staging)
            sdk = staging / 'flutter'
            if not expected_sdk(sdk):
                raise RuntimeError('Unexpected Flutter Git revision in archive.')
            sdk.rename(target)
    return target / 'bin/flutter.bat'


def runtime_directory():
    config = MOBILE / '.dart_tool/package_config.json'
    packages = json.loads(config.read_text(encoding='utf-8'))['packages']
    package = next(p for p in packages if p['name'] == 'onnxruntime_v2')
    uri = urlsplit(urljoin(config.as_uri(), package['rootUri']))
    if uri.scheme != 'file':
        raise RuntimeError('Expected an on-disk ONNX Runtime package.')
    folder = Path(url2pathname(('//' + uri.netloc if uri.netloc else '') + uri.path)) / 'windows'
    if not (folder / 'onnxruntime.dll').is_file():
        raise RuntimeError('Missing onnxruntime.dll in the locked dependency.')
    return folder


def main():
    if sys.platform != 'win32':
        raise RuntimeError('Run setup-windows.cmd in the local Windows checkout.')
    arch = os.environ.get('PROCESSOR_ARCHITEW6432') or os.environ.get('PROCESSOR_ARCHITECTURE', '')
    if arch.upper() != 'AMD64':
        raise RuntimeError(f'This SDK and the model runtime are packaged for x64. Detected {arch}.')
    git = find_git()
    if not git:
        install_package('Git.Git')
        git = find_git()
    if not git:
        raise RuntimeError('Reopen the Windows terminal after installing Git and retry.')
    os.environ['PATH'] = str(git.parent) + os.pathsep + os.environ['PATH']

    system = Path(os.environ['SystemRoot']) / ('System32' if sys.maxsize > 2**32 else 'Sysnative')
    if any(not (system / dll).is_file() for dll in
           ('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll')):
        install_package('Microsoft.VCRedist.2015+.x64')
    flutter = flutter_sdk()
    print(f'Flutter SDK: {flutter.parent.parent}', flush=True)
    os.environ['PATH'] = str(flutter.parent) + os.pathsep + os.environ['PATH']
    os.environ['FLUTTER_SUPPRESS_ANALYTICS'] = 'true'
    run(sys.executable, '-m', 'research.prepare_mobile')
    run(flutter, 'pub', 'get', '--enforce-lockfile', cwd=MOBILE)
    os.environ['PATH'] = str(runtime_directory()) + os.pathsep + os.environ['PATH']
    run(flutter, 'analyze', '--no-pub', cwd=MOBILE)
    run(flutter, 'test', '--no-pub', '--concurrency=1', '--reporter=expanded', 'test', cwd=MOBILE)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
