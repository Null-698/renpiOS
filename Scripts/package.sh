#!/usr/bin/env bash
set -euo pipefail

project=.build/project/renios/prototype/prototype.xcodeproj
mkdir -p out/diagnostics
xcodebuild -project "$project" -scheme prototype -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$PWD/.build/device" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build | tee out/diagnostics/device-build.log
app="$PWD/.build/device/Build/Products/Release-iphoneos/reniOS.app"
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT
mkdir "$staging/Payload"
ditto "$app" "$staging/Payload/reniOS.app"
rm -f out/reniOS-unsigned.ipa
ditto -c -k --keepParent "$staging/Payload" out/reniOS-unsigned.ipa
