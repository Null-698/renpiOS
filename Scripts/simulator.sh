#!/usr/bin/env bash
set -euo pipefail

major=${1:?pass the iOS major version}
mkdir -p out/diagnostics

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
bounded() {
  python3 -c 'import subprocess,sys; subprocess.run(sys.argv[2:], timeout=float(sys.argv[1]), check=True)' "$@"
}
capture() {
  bounded 10 xcrun simctl io "$udid" screenshot out/diagnostics/last-screen.png >/dev/null 2>&1 || true
  bounded 12 xcrun simctl spawn "$udid" log show --last 4m --predicate 'process == "reniOS"' \
    > out/diagnostics/reniOS.log 2>&1 || true
  if [[ -n "${data:-}" && -d "$data/Documents" ]]; then
    find "$data/Documents" \( -name log.txt -o -name traceback.txt \) -exec cp {} out/diagnostics/ \; || true
  fi
  bounded 8 xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
}
trap capture EXIT
bounded 150 xcrun simctl boot "$udid"
bounded 240 xcrun simctl bootstatus "$udid" -b
for preference in DidShowContinuousPathIntroduction DidShowGestureKeyboardIntroduction \
  KeyboardDidShowProductivityTutorial UIKeyboardDidShowInternationalInfoIntroduction; do
  bounded 30 xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences "$preference" -int 1
done
# Older simulator runtimes read the QuickPath intro status from this domain.
bounded 30 xcrun simctl spawn "$udid" defaults write com.apple.keyboard.ContinuousPath DidShowContinuousPathIntroduction -bool YES
bounded 30 xcrun simctl spawn "$udid" defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO
bounded 150 xcrun simctl install "$udid" "$app"
bounded 35 xcrun simctl launch "$udid" "$bundle"
sleep 3
xcrun simctl io "$udid" screenshot out/diagnostics/library.png
xcrun simctl terminate "$udid" "$bundle"
bounded 35 xcrun simctl launch "$udid" "$bundle" --keyboard-probe
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
probe="$data/Library/Caches/renios-keyboard.json"
for ((attempt=0; attempt<75; attempt++)); do
  [[ ! -s "$probe" ]] || break
  sleep 1
done
if [[ ! -s "$probe" ]]; then
  echo "Ren’Py did not report an on-screen keyboard within 75 seconds." >&2
  exit 1
fi
cp "$probe" out/keyboard-probe.json
cat out/keyboard-probe.json
jq -e '.keyboardVisible == true and .viewportStable == true' out/keyboard-probe.json
xcrun simctl io "$udid" screenshot out/keyboard.png
ditto -c -k --keepParent "$app" out/reniOS-simulator.zip
