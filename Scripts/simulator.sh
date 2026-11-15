#!/usr/bin/env bash
set -euo pipefail

major=${1:?pass the iOS major version}
mkdir -p out/diagnostics

app=${2:?pass the path to the shared simulator app}
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
device_data=$(xcrun simctl list devices -j | jq -r --arg udid "$udid" '
  [.devices[][] | select(.udid == $udid)][0].dataPath // empty')
if [[ -z "$device_data" ]]; then
  device_data="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data"
fi
python3 - "$device_data" <<'PYTHON'
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1]) / "Library" / "Preferences"
root.mkdir(parents=True, exist_ok=True)
settings = {
    "com.apple.keyboard.preferences": {
        "DidShowContinuousPathIntroduction": True,
        "DidShowGestureKeyboardIntroduction": True,
        "KeyboardDidShowProductivityTutorial": True,
        "UIKeyboardDidShowInternationalInfoIntroduction": True,
    },
    "com.apple.keyboard.ContinuousPath": {"DidShowContinuousPathIntroduction": True},
}
for domain, additions in settings.items():
    path = root / f"{domain}.plist"
    current = plistlib.loads(path.read_bytes()) if path.exists() else {}
    current.update(additions)
    temporary = path.with_suffix(".tmp")
    temporary.write_bytes(plistlib.dumps(current, fmt=plistlib.FMT_BINARY))
    temporary.replace(path)
PYTHON
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO
bounded 150 xcrun simctl boot "$udid"
bounded 240 xcrun simctl bootstatus "$udid" -b
bounded 150 xcrun simctl install "$udid" "$app"
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)

probe_playback() {
  local engine=$1
  local suffix=$2
  bounded 25 xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  rm -f "$data"/Library/Caches/renios-{library.json,keyboard.json,quit.json,quit.request}
  bounded 150 xcrun simctl launch "$udid" "$bundle" --keyboard-probe "$engine"
  probe="$data/Library/Caches/renios-keyboard.json"
  for ((attempt=0; attempt<75; attempt++)); do
    [[ ! -s "$probe" ]] || break
    sleep 1
  done
  if [[ ! -s "$probe" ]]; then
    echo "Ren’Py did not report an on-screen keyboard within 75 seconds." >&2
    exit 1
  fi
  cp "$data/Library/Caches/renios-library.json" "out/library-probe${suffix}.json"
  cat "out/library-probe${suffix}.json"
  jq -e '.importsAndSaves == true' "out/library-probe${suffix}.json"
  cp "$probe" "out/keyboard-probe${suffix}.json"
  cat "out/keyboard-probe${suffix}.json"
  jq -e '.keyboardVisible == true and .viewportStable == true' "out/keyboard-probe${suffix}.json"
  if [[ -z "$suffix" ]] && ! bounded 12 xcrun simctl io "$udid" screenshot out/keyboard.png; then
    echo "::warning::Keyboard screenshot unavailable"
  fi

  # Ask the running host to invoke the Close button’s native action, then
  # require the demo's confirmation screen and a clean return from Ren'Py.
  touch "$data/Library/Caches/renios-quit.request"
  quit="$data/Library/Caches/renios-quit.json"
  for ((attempt=0; attempt<75; attempt++)); do
    [[ ! -s "$quit" ]] || break
    sleep 1
  done
  if [[ ! -s "$quit" ]]; then
    echo "Ren’Py did not return from the Close action within 75 seconds." >&2
    exit 1
  fi
  cp "$quit" "out/quit-probe${suffix}.json"
  cat "out/quit-probe${suffix}.json"
  jq -e --arg engine "$engine" '.confirmed == true and .exitStatus == 0 and .engine == $engine' "out/quit-probe${suffix}.json"
}

probe_playback 8.6.0 ""
probe_playback 8.5.3 "-8.5.3"
