#!/usr/bin/env bash
# Generates the iPhone app's Xcode project from iOS/project.yml and builds it for the simulator.
# Needs xcodegen (`brew install xcodegen`). To put it on a phone, open iOS/EmberPhone.xcodeproj in
# Xcode, pick your team under Signing & Capabilities, choose your iPhone, and Run.
set -euo pipefail
cd "$(dirname "$0")/../iOS"
xcodegen generate --quiet
DEVICE="${DEVICE:-iPhone 17 Pro}"
xcodebuild -project EmberPhone.xcodeproj -scheme Ember -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
if [[ "${RUN:-}" == "1" ]]; then
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/Ember.app
  xcrun simctl launch "$DEVICE" dev.byldr.ember.phone
fi
