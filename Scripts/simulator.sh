#!/usr/bin/env bash
set -euo pipefail

major=${1:?pass the iOS major version}
mode=${3:-playback}
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
bounded 240 xcrun simctl bootstatus "$udid" -b
if [[ "$mode" == preview || ! -f out/launcher-preview/.installed ]]; then
  bounded 240 xcrun simctl install "$udid" "$app"
fi
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)

if [[ "$mode" == preview ]]; then
  mkdir -p out/launcher-preview
  touch out/launcher-preview/.installed
  for screen in Library Overview Saves Mods Export Restore landscape; do
    bounded 15 xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    if bounded 45 xcrun simctl launch "$udid" "$bundle" --launcher-preview "$screen"; then
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
  local file=$1
  for ((attempt=0; attempt<45; attempt++)); do
    [[ ! -s "$file" ]] || return 0
    sleep 1
  done
  echo "Timed out waiting for $(basename "$file")." >&2
  return 1
}

probe_playback() {
  local label=$1
  local check_rotation=$2
  shift 2
  local cache="$data/Library/Caches"
  local quit="$cache/renios-quit.json"
  bounded 25 xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  rm -f "$cache"/renios-{library.json,quit.json,quit.request,controls.json,controls.request}

  echo "Testing Ren’Py session: $*"
  bounded 90 xcrun simctl launch --stdout="$PWD/out/diagnostics/$label-stdout.log" \
    --stderr="$PWD/out/diagnostics/$label-stderr.log" "$udid" "$bundle" --playback-probe "$@" || return
  wait_for_probe "$cache/renios-library.json" || return
  cp "$cache/renios-library.json" "out/library-probe-$label.json" || return
  jq -e '.importsAndSaves == true' "out/library-probe-$label.json" || return

  local index=0 pid= engine result
  for engine in "$@"; do
    ((index+=1))
    if [[ "$check_rotation" == true && "$index" == 1 ]]; then
      local controls="$cache/renios-controls.json"
      touch "$cache/renios-controls.request" || return
      wait_for_probe "$controls" || return
      cp "$controls" "out/controls-probe-$label.json" || return
      cat "out/controls-probe-$label.json"
      jq -e '.rotated and .viewportFillsWindow and .drawableMatchesViewport' "out/controls-probe-$label.json" || return
      if [[ "$engine" == 7.4.11 ]]; then
        local drawable
        drawable=$(jq -r '.drawableSize' "$controls" | tr '{}' '()')
        grep -F "drawable=$drawable" "out/diagnostics/$label-stderr.log" || return
      fi
    fi

    touch "$cache/renios-quit.request" || return
    wait_for_probe "$quit" || return
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

failed=()
if ! probe_playback engine-switch false 8.6.0 7.4.11 8.6.0; then
  failed+=(engine-switch)
  tail -60 out/diagnostics/engine-switch-stderr.log || true
fi
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
