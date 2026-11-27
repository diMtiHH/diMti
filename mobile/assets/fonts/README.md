# Bundled offline typography — 0.6.1

Headings use **Cormorant Garamond** (Light 300, Regular 400, Medium 500, SemiBold 600). Body text and controls use **Literata** (Regular 400, Medium 500, SemiBold 600), instantiated at optical size 14 for readable interface text.

Both families come from official Google Fonts at pinned commit `b31870aff700ab7a1d74fa0c6887d95beb9e0037`: [Cormorant Garamond](https://github.com/google/fonts/tree/b31870aff700ab7a1d74fa0c6887d95beb9e0037/ofl/cormorantgaramond) and [Literata](https://github.com/google/fonts/tree/b31870aff700ab7a1d74fa0c6887d95beb9e0037/ofl/literata). Copyright remains with their respective Project Authors. Unmodified SIL Open Font License 1.1 texts are shipped as `CormorantGaramond-OFL.txt` and `Literata-OFL.txt`.

`sources.json` records all source URLs, SHA-256 hashes, byte counts, fixed axes and seven generated static faces. The helper checked Russian Cyrillic including Ё/ё, Latin, digits and punctuation in every face, weight metadata and absence of variable axes. No glyph subsetting or outline redesign was applied. Literata instance names identify their static weights.

Rebuild with `python mobile/tool/prepare_cosmic_fonts.py --fonttools-path <temporary fonttools 4.61.1 directory>`. FontTools is only an asset-preparation dependency. Source TTFs and upstream metadata preserve provenance; runtime loads only the seven registered static faces and two licenses, without any font download. Earlier Manrope source files remain historical evidence and are no longer registered or packaged.
