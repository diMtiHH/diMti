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
assert info.get('CFBundleShortVersionString') == '0.6.2', 'Wrong app version'
assert str(info.get('CFBundleVersion')) == '12', 'Wrong app build number'
assert info.get('UniverseEnglishNoticeApproved') is False
for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription', 'NSMotionUsageDescription'):
    assert isinstance(info.get(key), str) and info[key].strip(), key
for language in ('ru', 'en'):
    localized = plistlib.loads((app / f'{language}.lproj/InfoPlist.strings').read_bytes())
    for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription', 'NSMotionUsageDescription'):
        assert localized.get(key, '').strip(), (language, key)
assert not info.get('UIBackgroundModes'), 'Background recording is not authorized'
print('Local speech/motion permission descriptions RU/EN and closed notification flag: verified')
native = (app / info['CFBundleExecutable']).read_bytes()
for channel in ('presentation', 'voice', 'ambient', 'graphicsBudget', 'motion', 'haptics'):
    assert f'ask_universe/{channel}'.encode() in native, f'Missing native channel: {channel}'
print('Six native bridge channels: verified')
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

# These paths are the actual bundle lookup paths used by Flutter and native
# playback. Verify packaged bytes, not merely the source pubspec declarations.
flutter_assets = app / 'Frameworks/App.framework/flutter_assets'
font_source = repo / 'mobile/assets/fonts'
font_manifest = json.loads((font_source / 'sources.json').read_text(encoding='utf-8'))
packaged_fonts = json.loads((flutter_assets / 'FontManifest.json').read_text(encoding='utf-8'))
assert font_manifest['protocol'] == 'aura-offline-typography-v2'
assert font_manifest['runtime_network'] is False
assert {family['family'] for family in font_manifest['families']} == {'Cormorant Garamond', 'Literata', 'Manrope'}
for family in font_manifest['families']:
    packaged = [entry for entry in packaged_fonts if entry['family'] == family['family']]
    assert len(packaged) == 1, f'Missing or duplicate {family["family"]} family'
    assert {(entry['asset'], entry['weight']) for entry in packaged[0]['fonts']} == {
        (f'assets/fonts/{name}', entry['weight'])
        for name, entry in family['static_faces'].items()
    }, f'Wrong packaged {family["family"]} weights'
    license_name = family['license_file']
    for name, expected in {
        **family['static_faces'],
        license_name: family['source_files'][license_name],
    }.items():
        data = (flutter_assets / 'assets/fonts' / name).read_bytes()
        assert len(data) == expected['bytes'], name
        assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
print('Nine static Cormorant Garamond/Literata/Manrope faces and three SIL OFL licenses: verified')

ambient = flutter_assets / 'assets/audio/ambient'
ambient_source = repo / 'mobile/assets/audio/ambient'
ambient_metadata = (ambient / 'metadata.json').read_bytes()
assert ambient_metadata == (ambient_source / 'metadata.json').read_bytes(), 'Wrong ambient metadata'
ambient_manifest = json.loads(ambient_metadata)
assert ambient_manifest['provisional'] is True
for flag in ('default_enabled', 'final_sound_approved', 'speech', 'runtime_synthesis', 'third_party_recordings'):
    assert ambient_manifest[flag] is False, flag
assert ambient_manifest['native_max_player_volume'] <= 0.24
assert set(ambient_manifest['assets']) == {'stars.wav', 'galaxy.wav', 'aurora.wav', 'gravity.wav'}
for name, expected in ambient_manifest['assets'].items():
    path = ambient / name
    data = path.read_bytes()
    assert len(data) == expected['bytes'], name
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
    with wave.open(str(path), 'rb') as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (2, 2, 22050), name
        assert wav.getnframes() == 20 * 22050, name
print('Four original provisional ambient loops, default off: verified')

cue_metadata = (ambient / 'cues.json').read_bytes()
assert cue_metadata == (ambient_source / 'cues.json').read_bytes(), 'Wrong cue metadata'
cues = json.loads(cue_metadata)
assert cues['provisional'] is True and cues['answer_independent'] is True
for flag in ('final_sound_approved', 'third_party_recordings', 'speech', 'runtime_synthesis'):
    assert cues[flag] is False, flag
assert set(cues['assets']) == {'touch', 'transform', 'reveal'}
assert cues['native_max_player_volume'] <= .24
for event, expected in cues['assets'].items():
    assert expected['filename'] == f'cue-{event}.wav'
    path = ambient / expected['filename']
    data = path.read_bytes()
    assert len(data) == expected['bytes'], event
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], event
    with wave.open(str(path), 'rb') as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (2, 2, 22050), event
        assert wav.getnframes() == expected['frames'], event
        assert 0 < wav.getnframes() / wav.getframerate() <= 2, event
print('Three short neutral touch/transform/reveal cues: verified')

for name in ('aura_environment.frag', 'aura_matter.frag', 'aura_metal.frag'):
    data = (flutter_assets / 'shaders' / name).read_bytes()
    # IPLR is the compiled Impeller runtime-stage flatbuffer identifier. A raw
    # copied GLSL file cannot satisfy this check or work in the shipped renderer.
    assert len(data) > 128 and data[4:8] == b'IPLR', f'Uncompiled/missing shader: {name}'
    assert data != (repo / 'mobile/shaders' / name).read_bytes(), name
print('Three compiled AURA runtime shaders and version 0.6.2+12: verified')
