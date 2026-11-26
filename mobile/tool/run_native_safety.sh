#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t universe-native-safety)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -import-objc-header ios/Runner/ClockSemaphore.h \
  ios/Runner/ClockContinuity.swift ios/Runner/BoundedCallback.swift \
  tool/NativeSafetyTests.swift -o "$binary"
"$binary"
