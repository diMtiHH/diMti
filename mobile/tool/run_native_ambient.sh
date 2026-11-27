#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t universe-native-ambient)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/AmbientPolicy.swift tool/NativeAmbientTests.swift -o "$binary"
"$binary"
