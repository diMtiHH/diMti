# Manrope — bundled offline typography

Official source: [Google Fonts Manrope](https://github.com/google/fonts/tree/b31870aff700ab7a1d74fa0c6887d95beb9e0037/ofl/manrope), pinned commit `b31870aff700ab7a1d74fa0c6887d95beb9e0037`. Copyright belongs to the Manrope Project Authors. The unmodified license is included as `OFL.txt` (SIL Open Font License 1.1).

`Manrope-Light.ttf` (300), `Manrope-Regular.ttf` (400), `Manrope-Medium.ttf` (500), and `Manrope-SemiBold.ttf` (600) are static instances of the official variable source, prepared with fonttools 4.61.1. No glyph subsetting or outline redesign was applied. Latin, Russian Cyrillic including Ё/ё, and digits were checked in every output's cmap; weight metadata and absence of variable axes were checked too.

Source URLs, byte counts and SHA-256 values are in `sources.json`. `Manrope-Variable.source.ttf` and `upstream-METADATA.pb` preserve reproducible source evidence and are not registered as runtime font faces. Rebuild with `python mobile/tool/prepare_manrope.py`, using fonttools 4.61.1. FontTools is only an asset-preparation dependency. The app reads the four shipped faces without network access.
