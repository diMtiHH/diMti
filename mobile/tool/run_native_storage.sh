#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t universe-native-storage)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/SessionSchema.swift ios/Runner/SessionStorage.swift \
  tool/NativeStorageTests.swift -o "$binary"
"$binary"
