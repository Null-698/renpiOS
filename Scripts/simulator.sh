#!/usr/bin/env bash
set -euo pipefail

major=${1:?pass the iOS major version}
mode=${3:-playback}
mkdir -p out/diagnostics

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
capture() {
  bounded 10 xcrun simctl io "$udid" screenshot --display=1 out/diagnostics/last-screen.png >/dev/null 2>&1 || true
  bounded 12 xcrun simctl spawn "$udid" log show --last 4m --predicate 'process == "reniOS"' \
    > out/diagnostics/reniOS.log 2>&1 || true
  local log_root
  log_root=$(dirname "$device_data")/data/Library/Logs/CrashReporter
  if [[ -d "$log_root" ]]; then
    find "$log_root" -name 'reniOS*.ips' -exec cp {} out/diagnostics/ \; || true
  fi
  if [[ -n "${data:-}" && -d "$data/Documents" ]]; then
    find "$data/Documents" \( -name log.txt -o -name traceback.txt \) -exec cp {} out/diagnostics/ \; || true
  fi
  bounded 8 xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
}
if [[ "$mode" == playback ]]; then
  trap capture EXIT
fi
device_data=$(xcrun simctl list devices -j | jq -r --arg udid "$udid" '
  [.devices[][] | select(.udid == $udid)][0].dataPath // empty')
if [[ -z "$device_data" ]]; then
  device_data="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data"
fi
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
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)

if [[ "$mode" == preview ]]; then
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
  exit 0
fi

wait_for_probe() {
  local file=$1 timeout=$2 pid=$3
  local deadline=$((SECONDS + timeout))
  while [[ ! -s "$file" && "$SECONDS" -lt "$deadline" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Simulator app exited while waiting for $(basename "$file")." >&2
      return 1
    fi
    sleep 1
  done
  if [[ ! -s "$file" ]]; then
    echo "Timed out after $timeout seconds waiting for $(basename "$file")." >&2
    return 1
  fi
}

sample_app() {
  local pid=$1 label=$2
  if kill -0 "$pid" 2>/dev/null; then
    bounded 45 /usr/bin/sample "$pid" 2 10 -file "$PWD/out/diagnostics/$label-sample.log" || true
  fi
}

probe_playback() {
  local label=$1
  local check_rotation=$2
  shift 2
  local cache="$data/Library/Caches"
  local quit="$cache/renios-quit.json"
  bounded 25 xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  rm -f "$cache"/renios-{library.json,ready.json,quit.json,quit.request,controls.json,controls.request}

  echo "Testing Ren’Py session: $*"
  local launch
  # Exercise SDL audio initialization without depending on the runner's audio device.
  launch=$(SIMCTL_CHILD_SDL_AUDIODRIVER=dummy SIMCTL_CHILD_SDL_AUDIO_DRIVER=dummy \
    bounded 120 xcrun simctl launch --terminate-running-process --stdout="$PWD/out/diagnostics/$label-stdout.log" \
    --stderr="$PWD/out/diagnostics/$label-stderr.log" "$udid" "$bundle" --playback-probe "$@") || return
  echo "$launch"
  local app_pid=${launch##*: }
  if [[ ! "$app_pid" =~ ^[0-9]+$ ]]; then
    echo "Could not read the simulator app PID." >&2
    return 1
  fi
  wait_for_probe "$cache/renios-library.json" 90 "$app_pid" || return
  cp "$cache/renios-library.json" "out/library-probe-$label.json" || return
  jq -e '.importsAndSaves == true' "out/library-probe-$label.json" || return

  local index=0 pid= engine result
  for engine in "$@"; do
    ((index+=1))
    echo "Waiting for game $index on Ren’Py $engine to reach dialogue"
    if ! wait_for_probe "$cache/renios-ready.json" 120 "$app_pid"; then
      sample_app "$app_pid" "$label"
      return 1
    fi
    local ready="out/ready-probe-$label-$index.json"
    mv "$cache/renios-ready.json" "$ready" || return
    jq -e --arg engine "$engine" --arg project "Playback Probe $index" --argjson pid "$app_pid" \
      '.engine == $engine and (.project | startswith($project)) and .pid == $pid' "$ready" || return

    if [[ "$check_rotation" == true && "$index" == 1 ]]; then
      local controls="$cache/renios-controls.json"
      touch "$cache/renios-controls.request" || return
      wait_for_probe "$controls" 60 "$app_pid" || return
      cp "$controls" "out/controls-probe-$label.json" || return
      cat "out/controls-probe-$label.json"
      jq -e '.rotated and .viewportFillsWindow and .drawableMatchesViewport' "out/controls-probe-$label.json" || return
      if [[ "$engine" == 7.4.11 ]]; then
        local drawable
        drawable=$(jq -r '.drawableSize' "$controls" | tr '{}' '()')
        grep -F "drawable=$drawable" "out/diagnostics/$label-stderr.log" || return
      fi
    fi

    echo "Requesting Close for game $index"
    touch "$cache/renios-quit.request" || return
    if ! wait_for_probe "$quit" 60 "$app_pid"; then
      sample_app "$app_pid" "$label"
      return 1
    fi
    result="out/quit-probe-$label-$index.json"
    mv "$quit" "$result" || return
    cat "$result"
    jq -e --arg engine "$engine" --arg project "Playback Probe $index" \
      '.confirmed and .exitStatus == 0 and .engine == $engine and .usesGameSaves and
       (.project | startswith($project)) and .pid > 0' "$result" || return

    if [[ -z "$pid" ]]; then
      pid=$(jq -r '.pid' "$result") || return
    elif [[ "$(jq -r '.pid' "$result")" != "$pid" ]]; then
      echo "The app process changed during the session." >&2
      return 1
    fi
  done
}

if [[ "$mode" == smoke ]]; then
  if ! probe_playback engine-switch false 8.6.0 7.4.11 8.6.0; then
    tail -100 out/diagnostics/engine-switch-stderr.log || true
    exit 1
  fi
  exit 0
fi

failed=()
while IFS= read -r engine; do
  rotation=false
  if [[ "$engine" == 8.6.0 || "$engine" == 7.4.11 ]]; then
    rotation=true
  fi
  if ! probe_playback "$engine" "$rotation" "$engine" "$engine"; then
    failed+=("$engine")
    tail -60 "out/diagnostics/$engine-stderr.log" || true
  fi
done < <(python3 - "$app/Info.plist" <<'PYTHON'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
default = info["ReniosEngineVersion"]
available = info["ReniosInstalledEngines"]
priority = [v for v in (default, "7.4.11", "8.5.3", "8.3.7", "7.8.7") if v in available]
for version in priority + [v for v in available if v not in priority]:
    print(version)
PYTHON
)
if ((${#failed[@]})); then
  echo "Failed playback checks: ${failed[*]}" >&2
  exit 1
fi
