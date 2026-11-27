#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t universe-native-presentation)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/PresentationSchema.swift ios/Runner/PresentationStorage.swift \
  tool/NativePresentationTests.swift -o "$binary"
"$binary"
