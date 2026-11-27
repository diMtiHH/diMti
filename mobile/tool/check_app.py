"""Verify the packaged iOS asset location used by the Flutter isolate."""
import hashlib
import json
import plistlib
from pathlib import Path
import sys
import wave

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
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info.get('UniverseEnglishNoticeApproved') is False
for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
    assert isinstance(info.get(key), str) and info[key].strip(), key
for language in ('ru', 'en'):
    localized = plistlib.loads((app / f'{language}.lproj/InfoPlist.strings').read_bytes())
    for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
        assert localized.get(key, '').strip(), (language, key)
assert not info.get('UIBackgroundModes'), 'Background recording is not authorized'
print('Local speech permission descriptions RU/EN and closed notification flag: verified')
onboarding = app / 'Frameworks/App.framework/flutter_assets/assets/onboarding'
metadata = json.loads((onboarding / 'narration.json').read_text(encoding='utf-8'))
script = json.loads((onboarding / 'script.json').read_text(encoding='utf-8'))
assert metadata['termsVersion'] == script['termsVersion'] == 1
assert metadata['provisionalNarration'] is True
assert metadata['englishWordingApproved'] is False
for language in ('ru', 'en'):
    track = metadata['languages'][language]
    path = onboarding / f'{language}.wav'
    assert hashlib.sha256(path.read_bytes()).hexdigest() == track['sha256']
    assert [s['text'] for s in track['segments']] == script[language]
    with wave.open(str(path), 'rb') as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 22050)
        assert abs(wav.getnframes() / wav.getframerate() * 1000 - track['durationMs']) < 1
    for segment in track['segments']:
        assert 0 <= segment['startMs'] < segment['endMs'] <= track['durationMs']
print('Bundled provisional narration RU/EN, timing and text: verified')
