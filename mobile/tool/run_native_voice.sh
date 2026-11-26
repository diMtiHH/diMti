#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t universe-native-voice)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/VoicePolicy.swift tool/NativeVoiceTests.swift -o "$binary"
"$binary"
