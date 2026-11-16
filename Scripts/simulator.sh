#!/usr/bin/env bash
set -euo pipefail

major=${1:?pass the iOS major version}

app=${2:?pass the path to the shared simulator app}
test -d "$app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
runtimes=$(xcrun simctl list runtimes -j)
devices=$(xcrun simctl list devices available -j)
selection=$(jq -nr --argjson runtimes "$runtimes" --argjson devices "$devices" --arg major "$major" '
  [$runtimes.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-")) and
    (.version | split(".")[0] == $major)) as $runtime |
    $devices.devices[$runtime.identifier][]? |
    select(.isAvailable and (.name | startswith("iPhone"))) |
    { udid, name, runtime: $runtime.identifier, version: ($runtime.version | split(".") | map(tonumber)) }] |
  sort_by([(.name | test("Duo"; "i")), (.version | map(-.)),
           (if (.name == "iPhone 17" or .name == "iPhone 18") then 0 else 1 end), .name, .udid]) |
  first | if . then [.runtime, .udid] | @tsv else empty end')
IFS=$'\t' read -r runtime udid <<< "$selection"
if [[ -z "$udid" ]]; then
  xcrun simctl list
  echo "No preconfigured iPhone for iOS $major" >&2
  exit 1
fi
echo "Testing $bundle on $runtime ($udid)"
bounded() {
  python3 -c 'import subprocess,sys; subprocess.run(sys.argv[2:], timeout=float(sys.argv[1]), check=True)' "$@"
}
state=$(xcrun simctl list devices -j | jq -r --arg udid "$udid" '
  [.devices[][] | select(.udid == $udid)][0].state')
if [[ "$state" == Shutdown ]]; then
  bounded 150 xcrun simctl boot "$udid"
fi
if ! bounded 240 xcrun simctl bootstatus "$udid" -b; then
  bounded 120 xcrun simctl bootstatus "$udid" -b
fi
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")
is_current_install() {
  local installed
  installed=$(bounded 20 xcrun simctl get_app_container "$udid" "$bundle" app 2>/dev/null) &&
    cmp -s "$app/$executable" "$installed/$executable"
}
if ! is_current_install; then
  echo "Installing $bundle"
  if ! bounded 240 xcrun simctl install "$udid" "$app" && ! is_current_install; then
    echo "::warning::Retrying the simulator app installation"
    bounded 240 xcrun simctl install "$udid" "$app"
  fi
fi
mkdir -p out/launcher-preview
for screen in Library Overview Saves Mods Export Restore landscape; do
  bounded 15 xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  if bounded 45 xcrun simctl launch --terminate-running-process "$udid" "$bundle" --launcher-preview "$screen"; then
    sleep 3
    if ! bounded 30 xcrun simctl io "$udid" screenshot --display=1 "out/launcher-preview/$screen.png"; then
      echo "::warning::Could not capture the $screen preview"
    fi
  fi
done
bounded 15 xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
