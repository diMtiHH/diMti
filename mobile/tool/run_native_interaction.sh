#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t universe-native-interaction)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/InteractionPolicy.swift tool/NativeInteractionTests.swift -o "$binary"
"$binary"
