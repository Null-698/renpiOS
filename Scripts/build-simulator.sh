#!/usr/bin/env bash
set -euo pipefail

project=.build/project/renios/prototype/prototype.xcodeproj
mkdir -p out/diagnostics
xcodebuild -project "$project" -scheme prototype -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$PWD/.build/simulator" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG build \
  | tee out/diagnostics/simulator-build.log

if [[ -d .build/project/engines ]]; then
  app="$PWD/.build/simulator/Build/Products/Debug-iphonesimulator/reniOS.app"
  python3 Scripts/embed-engine.py "$app" iphonesimulator
fi
