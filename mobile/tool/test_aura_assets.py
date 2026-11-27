"""Validate bundled font/audio bytes and reproducible audio properties offline."""
from array import array
import hashlib
import json
from pathlib import Path
import sys
import struct
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1] / 'assets'


class AuraAssetsTests(unittest.TestCase):
    def test_app_icons_match_catalog_and_are_opaque_rgb(self):
        folder = ROOT.parent / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
        catalog = json.loads((folder / 'Contents.json').read_text(encoding='utf-8'))
        manifest = json.loads((ROOT / 'identity/app-icon-manifest.json').read_text(encoding='utf-8'))
        self.assertFalse(manifest['transparency'])
        self.assertFalse(manifest['final_brand_acceptance'])
        self.assertEqual(manifest['color_mode'], 'RGB')
        self.assertEqual(set(manifest['exports']), {entry['filename'] for entry in catalog['images']})
        for entry in catalog['images']:
            name = entry['filename']
            expected = manifest['exports'][name]
            data = (folder / name).read_bytes()
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            self.assertEqual(data[12:16], b'IHDR')
            width, height, depth, color = struct.unpack('>IIBB', data[16:26])
            size = int(float(entry['size'].split('x')[0]) * float(entry['scale'].removesuffix('x')))
            self.assertEqual((width, height, depth, color), (size, size, 8, 2))
            self.assertEqual(expected['size_px'], size)
            self.assertEqual(expected['bytes'], len(data))
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected['sha256'])

    def test_fonts_match_pinned_sources_and_static_weights(self):
        folder = ROOT / 'fonts'
        manifest = json.loads((folder / 'sources.json').read_text(encoding='utf-8'))
        self.assertEqual(manifest['google_fonts_commit'], 'b31870aff700ab7a1d74fa0c6887d95beb9e0037')
        self.assertEqual({entry['weight'] for entry in manifest['static_faces'].values()}, {300, 400, 500, 600})
        self.assertEqual(len(manifest['static_faces']), 4)
        for name, entry in {**manifest['source_files'], **manifest['static_faces']}.items():
            data = (folder / name).read_bytes()
            self.assertEqual(len(data), entry['bytes'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry['sha256'])
        license_text = (folder / 'OFL.txt').read_text(encoding='utf-8')
        self.assertIn('SIL OPEN FONT LICENSE Version 1.1', license_text)
        self.assertIn('The Manrope Project Authors', license_text)

    def test_ambient_is_provisional_and_off_by_default(self):
        manifest = json.loads((ROOT / 'audio/ambient/metadata.json').read_text(encoding='utf-8'))
        self.assertTrue(manifest['provisional'])
        for flag in ['final_sound_approved', 'third_party_recordings', 'speech', 'runtime_synthesis', 'default_enabled']:
            self.assertFalse(manifest[flag])
        self.assertLessEqual(manifest['native_max_player_volume'], 0.24)
        self.assertEqual(set(manifest['assets']), {'stars.wav', 'galaxy.wav', 'aurora.wav', 'gravity.wav'})

    def test_audio_format_hash_quiet_peak_and_seam(self):
        folder = ROOT / 'audio/ambient'
        manifest = json.loads((folder / 'metadata.json').read_text(encoding='utf-8'))
        digests = set()
        for name, entry in manifest['assets'].items():
            path = folder / name
            data = path.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(digest, entry['sha256'])
            self.assertEqual(len(data), entry['bytes'])
            digests.add(digest)
            with wave.open(str(path), 'rb') as audio:
                self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()), (2, 2, 22050))
                self.assertEqual(audio.getnframes(), 20 * 22050)
                samples = array('h', audio.readframes(audio.getnframes()))
            if sys.byteorder != 'little': samples.byteswap()
            self.assertLess(max(map(abs, samples)), 32767 * 0.16)
            self.assertLessEqual(abs(samples[0] - samples[-2]), 1)
            self.assertLessEqual(abs(samples[1] - samples[-1]), 1)
            self.assertLess(entry['peak_dbfs'], -18)
        self.assertEqual(len(digests), 4)

    def test_neutral_cues_are_short_quiet_and_answer_independent(self):
        folder = ROOT / 'audio/ambient'
        metadata = json.loads((folder / 'cues.json').read_text(encoding='utf-8'))
        self.assertTrue(metadata['provisional'])
        self.assertTrue(metadata['answer_independent'])
        for flag in ('final_sound_approved', 'third_party_recordings', 'speech', 'runtime_synthesis'):
            self.assertFalse(metadata[flag])
        self.assertEqual(set(metadata['assets']), {'touch', 'transform', 'reveal'})
        self.assertLessEqual(metadata['native_max_player_volume'], .24)
        for event, expected in metadata['assets'].items():
            self.assertEqual(expected['filename'], f'cue-{event}.wav')
            path = folder / expected['filename']
            data = path.read_bytes()
            self.assertEqual(len(data), expected['bytes'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected['sha256'])
            with wave.open(str(path), 'rb') as audio:
                self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()), (2, 2, 22050))
                self.assertEqual(audio.getnframes(), expected['frames'])
                self.assertLessEqual(audio.getnframes() / audio.getframerate(), 2)
                samples = array('h', audio.readframes(audio.getnframes()))
            if sys.byteorder != 'little': samples.byteswap()
            self.assertLess(max(map(abs, samples)), 32767 * .08)
            self.assertEqual([samples[0], samples[1], samples[-2], samples[-1]], [0, 0, 0, 0])


if __name__ == '__main__':
    unittest.main()
