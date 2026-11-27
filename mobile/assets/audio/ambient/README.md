# Provisional AURA 13 ambient audio

Four original sound beds are generated offline by `mobile/tool/prepare_ambient_audio.py` using only mathematical oscillators. They contain no voice, microphone recording, third-party music or user information. Each environment has different frequencies and modulation. Files are 20-second, stereo, 16-bit PCM WAV loops at 22,050 Hz; smooth zero-valued endpoints avoid a loop-boundary discontinuity. The generator checks clipping and endpoint continuity and records SHA-256, duration, peak and RMS in `metadata.json`.

The app plays shipped files, without synthesis or network access. Ambient sound is off by default and separate from onboarding narration. The native player uses a low fixed maximum volume of 0.24, fades in, and stops for background, interruption, route change or microphone ownership. Returning to the foreground does not resume an interrupted loop automatically.

`prepare_ambient_cues.py` adds three original short, softly enveloped cues:
`cue-touch.wav` (0.24 s), `cue-transform.wav` (1.2 s), and `cue-reveal.wav`
(0.8 s). `cues.json` records their hashes, levels and provisional status.
The same reveal sound is used for both answers; the playback API accepts only
an event name and never receives the answer or question. A separate native
player borrows the currently active ambient session, cannot activate an audio
session itself, never overlaps multiple cues, and stops with the ambient loop.
No cue plays when sound is disabled, interrupted, in the background or capturing
speech. Their zero endpoints and peak below -23 dBFS are checked automatically.

These original assets are the sound candidate shipped in personal 0.8.0, with explicit cue previews in settings. Automated level, continuity, ownership and interruption checks cover them. Final timbre, listening comfort on physical devices and founder acceptance remain unconfirmed; the metadata deliberately preserves that distinction. See `docs/STAGE_8.md` for implementation and acceptance boundaries.
