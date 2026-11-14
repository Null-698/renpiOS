#!/usr/bin/env bash
set -euo pipefail

major=${1:?pass the iOS major version}
project=.build/project/renios/prototype/prototype.xcodeproj
[[ -d "$project" ]]
mkdir -p out/diagnostics

xcodebuild -project "$project" -scheme prototype -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$PWD/.build/simulator" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build \
  | tee out/diagnostics/simulator-build.log

app="$PWD/.build/simulator/Build/Products/Debug-iphonesimulator/reniOS.app"
test -d "$app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
runtime=$(xcrun simctl list runtimes -j | jq -r --arg version "$major" '
  [.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-")) and
  (.version | split(".")[0] == $version))] | sort_by(.version | split(".") | map(tonumber)) | .[-1].identifier // empty')
test -n "$runtime"
udid=$(xcrun simctl list devices available -j | jq -r --arg runtime "$runtime" '
  [.devices[$runtime][]? | select(.isAvailable and (.name | startswith("iPhone")))] |
  sort_by(if (.name == "iPhone 17" or .name == "iPhone 18") then 0 else 1 end) |
  .[0].udid // empty')
if [[ -z "$udid" ]]; then
  xcrun simctl list
  echo "No preconfigured iPhone for $runtime" >&2
  exit 1
fi
echo "Testing $bundle on $runtime ($udid)"
capture() {
  xcrun simctl io "$udid" screenshot out/diagnostics/last-screen.png >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" log show --last 4m --predicate 'process == "reniOS"' \
    > out/diagnostics/reniOS.log 2>&1 || true
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
}
trap capture EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl spawn "$udid" defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO || true
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$bundle"
sleep 3
xcrun simctl io "$udid" screenshot out/diagnostics/library.png
xcrun simctl terminate "$udid" "$bundle"
xcrun simctl launch "$udid" "$bundle" --keyboard-probe
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
probe="$data/Library/Caches/renios-keyboard.json"
for ((attempt=0; attempt<45; attempt++)); do
  [[ ! -s "$probe" ]] || break
  sleep 1
done
test -s "$probe"
cp "$probe" out/keyboard-probe.json
jq -e '.keyboardVisible == true and .viewportStable == true' out/keyboard-probe.json
xcrun simctl io "$udid" screenshot out/keyboard.png
ditto -c -k --keepParent "$app" out/reniOS-simulator.zip
