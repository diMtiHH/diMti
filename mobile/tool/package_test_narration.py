"""Package development-time Windows narration into bundled offline WAV assets."""
import hashlib
import json
from pathlib import Path
import wave

mobile = Path(__file__).resolve().parents[1]
assets = mobile / 'assets/onboarding'
script = json.loads((assets / 'script.json').read_text(encoding='utf-8'))
metadata = {'termsVersion': script['termsVersion'], 'provisionalNarration': True,
            'englishWordingApproved': False, 'languages': {}}
rate = 22050
gap_frames = rate // 5
for language, voice in [('ru', 'Microsoft Pavel'), ('en', 'Microsoft Zira')]:
    frames = bytearray()
    segments = []
    for index, text in enumerate(script[language]):
        source = mobile / f'build/stage5/audio/{language}-{index}.wav'
        with wave.open(str(source), 'rb') as wav:
            assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, rate)
            audio = wav.readframes(wav.getnframes())
        start = round(len(frames) / 2 / rate * 1000)
        frames.extend(audio)
        end = round(len(frames) / 2 / rate * 1000)
        segments.append({'text': text, 'startMs': start, 'endMs': end})
        if index != len(script[language]) - 1:
            frames.extend(bytes(gap_frames * 2))
    target = assets / f'{language}.wav'
    with wave.open(str(target), 'wb') as wav:
        wav.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        wav.writeframes(frames)
    metadata['languages'][language] = {
        'voice': voice, 'durationMs': round(len(frames) / 2 / rate * 1000),
        'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'segments': segments,
    }
(assets / 'narration.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({k: {'durationMs': v['durationMs'], 'sha256': v['sha256']}
                  for k, v in metadata['languages'].items()}))
