#!/bin/zsh
# Builds Glint (Debug) and relaunches it.
set -e
cd "$(dirname "$0")/.."
xcodebuild -project Glint.xcodeproj -scheme Glint -configuration Debug -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
pkill -x Glint 2>/dev/null || true
sleep 0.5
open build/DerivedData/Build/Products/Debug/Glint.app
