#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
xcodebuild -project WorkLedger.xcodeproj -scheme WorkLedger -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual "$@" build
echo "App: $project_root/build/Build/Products/Release/WeekStride.app"
