# AURA 13 identity

The app icon is the project's original four-ray energy mark with an offset
orbital arc. The same source `AuraIconPainter` in `mobile/lib/aura_ui.dart`
draws the in-app mark. It uses no external image, trademark artwork or font glyph.

`mobile/test/aura_ui_test.dart` renders its composition on an opaque dark radial
background to `mobile/build/stage6/aura-brand-candidate.png` (1024 × 1024).
`mobile/tool/prepare_aura_app_icon.py` exports the catalog sizes into the existing
`mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/` paths. All shipped PNGs
use RGB with no alpha channel, including the App Store image. The generator
checks opacity before export. `app-icon-manifest.json` records source and output
SHA-256 values; it is preparation evidence, not a runtime asset.

Rebuild after changing the vector or composition:

```text
cd mobile
flutter test test/aura_ui_test.dart
python tool/prepare_aura_app_icon.py --pillow-path TEMP_DIRECTORY
```

Pillow 12.0.0 is only used during offline asset preparation. The app has no image
library or download dependency. This is the implemented Stage 6 identity;
final brand acceptance and physical display review remain deferred.
