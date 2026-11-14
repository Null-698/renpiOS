#!/usr/bin/env bash
set -euo pipefail

project=.build/project/renios/prototype/prototype.xcodeproj
mkdir -p out/diagnostics
xcodebuild -project "$project" -scheme prototype -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$PWD/.build/simulator" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build \
  | tee out/diagnostics/simulator-build.log

