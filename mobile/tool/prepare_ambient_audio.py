"""Create original, quiet, offline ambient loops; no recordings or external assets.

These are provisional AURA 13 sound beds, not approved final Stage 8 sound design.
Only the Python standard library is required. No user question/audio is read.
"""
from array import array
import hashlib
import json
import math
from pathlib import Path
import sys
import wave

RATE = 22050
SECONDS = 20
VOICES = {
    'stars': ([196, 294, 392, 588], [1, 0.48, 0.20, 0.07], 1, 0.10),
    'galaxy': ([65.4, 98.1, 130.8, 196.2], [1, 0.65, 0.25, 0.10], 2, 0.22),
    'aurora': ([110, 164.8, 220, 329.6], [1, 0.42, 0.23, 0.08], 3, 0.36),
    'gravity': ([41.2, 61.8, 82.4, 164.8], [1, 0.58, 0.20, 0.06], 1, 0.13),
}


def main():
    destination = Path(__file__).resolve().parents[1] / 'assets' / 'audio' / 'ambient'
    destination.mkdir(parents=True, exist_ok=True)
    assets = {}
    for environment, (frequencies, weights, drift, depth) in VOICES.items():
        pcm = array('h')
        peak, square_sum = 0.0, 0.0
        count = RATE * SECONDS
        for i in range(count):
            turn = 2 * math.pi * i / count
            # Envelope and all oscillators use integer cycles per loop. The
            # endpoint fades to zero, so looping cannot create a boundary click.
            envelope = math.sin(turn / 2) ** 2
            for channel in range(2):
                sample = 0.0
                for j, (frequency, weight) in enumerate(zip(frequencies, weights)):
                    cycles = round(frequency * SECONDS)
                    modulation = depth * math.sin(turn * drift + j * 0.7 + channel * 0.35)
                    breathing = 0.75 + 0.25 * math.cos(turn * (j + 1) + channel * 0.4)
                    sample += weight * breathing * math.sin(turn * cycles + modulation)
                sample *= 0.065 * envelope
                assert abs(sample) < 0.16
                peak = max(peak, abs(sample))
                square_sum += sample * sample
                pcm.append(round(sample * 32767))
        assert abs(pcm[0] - pcm[-2]) <= 1 and abs(pcm[1] - pcm[-1]) <= 1
        if sys.byteorder != 'little':
            pcm.byteswap()
        path = destination / f'{environment}.wav'
        with wave.open(str(path), 'wb') as output:
            output.setnchannels(2)
            output.setsampwidth(2)
            output.setframerate(RATE)
            output.writeframes(pcm.tobytes())
        content = path.read_bytes()
        assets[path.name] = {
            'sha256': hashlib.sha256(content).hexdigest(), 'bytes': len(content),
            'duration_seconds': SECONDS, 'sample_rate': RATE, 'channels': 2,
            'pcm_bits': 16, 'peak_dbfs': round(20 * math.log10(peak), 2),
            'rms_dbfs': round(20 * math.log10(math.sqrt(square_sum / len(pcm))), 2),
            'seam_endpoint_delta_pcm': 0,
        }
    metadata = {
        'protocol': 'aura13-provisional-ambient-v1',
        'provisional': True, 'final_sound_approved': False,
        'origin': 'Original mathematical oscillators, generated offline for this project',
        'third_party_recordings': False, 'speech': False, 'runtime_synthesis': False,
        'default_enabled': False, 'native_max_player_volume': 0.24,
        'generator': 'mobile/tool/prepare_ambient_audio.py', 'assets': assets,
    }
    (destination / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    main()
