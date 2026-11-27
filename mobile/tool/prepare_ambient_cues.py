"""Original quiet gesture/transition cues, generated offline with stdlib only."""
from array import array
import hashlib
import json
import math
from pathlib import Path
import sys
import wave

RATE = 22050
# No ascending success chord, descending failure chord, voice or answer mapping.
CUES = {'touch': (0.24, 176, 0.046), 'transform': (1.2, 92, 0.046),
        'reveal': (0.8, 132, 0.052)}
folder = Path(__file__).resolve().parents[1] / 'assets/audio/ambient'
folder.mkdir(parents=True, exist_ok=True)
assets = {}
for event, (duration, frequency, gain) in CUES.items():
    count = round(duration * RATE)
    samples = array('h')
    peak, square_sum = 0.0, 0.0
    for index in range(count):
        position = index / (count - 1)
        seconds = index / RATE
        envelope = math.sin(math.pi * position) ** 2
        for channel in range(2):
            phase = 2 * math.pi * frequency * seconds
            softness = .11 * math.sin(2 * math.pi * position + channel * .2)
            value = gain * envelope * (math.sin(phase + softness) +
                .24 * math.sin(phase * 1.5 - softness) + .08 * math.sin(phase * 2))
            peak = max(peak, abs(value))
            square_sum += value * value
            samples.append(round(value * 32767))
    assert samples[0] == samples[1] == samples[-1] == samples[-2] == 0
    assert peak < .08
    if sys.byteorder != 'little': samples.byteswap()
    path = folder / f'cue-{event}.wav'
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        audio.writeframes(samples.tobytes())
    data = path.read_bytes()
    assets[event] = {'filename': path.name, 'sha256': hashlib.sha256(data).hexdigest(),
        'bytes': len(data), 'frames': count, 'duration_seconds': duration,
        'peak_dbfs': round(20 * math.log10(peak), 2),
        'rms_dbfs': round(20 * math.log10(math.sqrt(square_sum / len(samples))), 2)}
metadata = {'protocol': 'aura13-neutral-cues-v1', 'provisional': True,
    'final_sound_approved': False, 'origin': 'Original offline mathematical oscillators',
    'third_party_recordings': False, 'speech': False, 'runtime_synthesis': False,
    'answer_independent': True, 'native_max_player_volume': .24,
    'generator': 'mobile/tool/prepare_ambient_cues.py', 'assets': assets}
(folder / 'cues.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
print(json.dumps(metadata, indent=2))
