#!/bin/bash
# Run the layout audit across every iPhone width and two text sizes.
#
# The audit itself is `WrittenUITests`; this only drives it. One simulator at a
# time, deliberately — CoreSimulator falls over under parallel boots and this
# project has already lost a day to `backboardd` crashing, so a slow sweep that
# finishes beats a fast one that has to be restarted.
#
#   ./tools/run_layout_audit.sh            # the whole matrix
#   ./tools/run_layout_audit.sh se3        # one device
#
# Then:
#   python3 tools/layout_audit.py out/layout/*/

set -uo pipefail
cd "$(dirname "$0")/.."

OUT="${LAYOUT_AUDIT_OUT:-out/layout}"
mkdir -p "$OUT"

# name:device type:points, smallest first. The two 375-wide entries are not a
# duplicate: the garden square is height-limited, so an SE and a 13 mini share a
# width and size the plant differently.
DEVICES=(
    "se3:iPhone-SE-3rd-generation:375x667"
    "mini:iPhone-13-mini:375x812"
    "i17:iPhone-17:393x852"
    "pro:iPhone-17-Pro:402x874"
    "max:iPhone-17-Pro-Max:440x956"
)

# Default, and the largest the system offers. The interesting one is the second:
# `BrandFont` scales with it and the 165 `.system(size:)` calls do not, so this
# is where fixed-height containers and growing text collide.
SIZES=("large:default" "accessibility-extra-extra-extra-large:accessibility")

only="${1:-}"

udid_for() {
    local name="$1" type="$2" existing
    existing=$(xcrun simctl list devices -j \
        | python3 -c "
import json,sys
want='audit-$name'
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == want:
            print(d['udid']); raise SystemExit
")
    if [ -n "$existing" ]; then echo "$existing"; return; fi
    local runtime
    runtime=$(xcrun simctl list runtimes | grep -o "com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*" | tail -1)
    xcrun simctl create "audit-$name" \
        "com.apple.CoreSimulator.SimDeviceType.$type" "$runtime"
}

for entry in "${DEVICES[@]}"; do
    IFS=: read -r name type points <<< "$entry"
    [ -n "$only" ] && [ "$only" != "$name" ] && continue

    udid=$(udid_for "$name" "$type")
    [ -z "$udid" ] && { echo "!! could not get a simulator for $name"; continue; }

    echo "=== $name ($points) $udid"
    xcrun simctl boot "$udid" 2>/dev/null
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1

    for size in "${SIZES[@]}"; do
        IFS=: read -r category label <<< "$size"
        echo "--- $name / $label"
        xcrun simctl ui "$udid" content_size "$category" >/dev/null 2>&1

        run="$OUT/${name}_${label}"
        rm -rf "$run.xcresult" "$run"

        # Not fatal on failure: a device that dies should cost its own run and
        # not the fourteen after it. A missing dump is visible in the report as
        # a screen with no entry, which is the finding rather than a silent gap.
        xcodebuild test-without-building \
            -project Written.xcodeproj -scheme Written -sdk iphonesimulator \
            -destination "platform=iOS Simulator,id=$udid" \
            -configuration Debug -only-testing:WrittenUITests \
            -resultBundlePath "$run.xcresult" \
            > "$run.log" 2>&1 \
            || echo "   (xcodebuild reported failure — log kept)"

        # The dumps come out of the result bundle, not the log. A UI test
        # runner's stdout does not reach `xcodebuild` — measured: a clean
        # 14-screen run produced `** TEST EXECUTE SUCCEEDED **` and not one
        # marker. The attachments are the channel that works.
        #
        # The directory name carries the content size, and `layout_audit.py`
        # reads it from there to pair a label against itself at two text sizes.
        # Renaming these breaks the clamped-label check silently.
        mkdir -p "$run"
        xcrun xcresulttool export attachments \
            --path "$run.xcresult" --output-path "$run" >/dev/null 2>&1

        echo "    $(ls "$run"/*.json 2>/dev/null | grep -vc manifest) screens dumped"
    done

    xcrun simctl shutdown "$udid" >/dev/null 2>&1
done

echo
echo "Now: python3 tools/layout_audit.py $OUT/*/"
