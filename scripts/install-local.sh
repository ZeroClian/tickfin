#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Reuse one non-indexed build directory, then replace a single installed application.
work_root="${TICKFIN_WORK_ROOT:-${TMPDIR:-/tmp}/tickfin-build.noindex}"
export TICKFIN_BUILD_ROOT="$work_root/build"
export TICKFIN_APP_PATH="$work_root/Tickfin.app"
bash "$project_root/scripts/build-app.sh"
target="/Applications/Tickfin.app"
if [ ! -w /Applications ]; then
    printf '%s\n' 'Applications is not writable. Install with an account that can replace Tickfin there.' >&2
    exit 1
fi
# Refuse to overwrite an unrelated bundle or a symlink.
if [ -e "$target" ]; then
    [ ! -L "$target" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" = local.stockbar.app ]
fi
if pgrep -x StockBar >/dev/null; then
    printf '%s\n' 'Quit Tickfin before installing; the build is ready. Re-run this command after quitting.' >&2
    exit 1
fi
token="$(uuidgen)"
stage="/Applications/.Tickfin-update-$token.noindex"
mkdir -m 700 "$stage"
trap 'rm -rf "$stage"' EXIT
if [ ! -e "$target" ]; then
    ditto "$TICKFIN_APP_PATH" "$stage/new.app"
    mv "$stage/new.app" "$target"
    open -g "$target"
else
    mkdir "$stage/payload"
    ditto "$TICKFIN_APP_PATH" "$stage/payload/Tickfin.app"
    cp "$TICKFIN_APP_PATH/Contents/MacOS/StockBar" "$stage/update-helper"
    plan="$stage/plan.json"
    # Some plutil versions cannot preserve JSON during -insert. Edit an XML
    # plist first, then convert once to the JSON consumed by UpdateTransaction.
    plutil -create xml1 "$plan"
    plutil -insert root -string "file://$stage/" "$plan"
    plutil -insert target -string "file://$target/" "$plan"
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TICKFIN_APP_PATH/Contents/Info.plist")"
    plutil -insert version -string "$version" "$plan"
    plutil -insert parentPID -integer "$$" "$plan"
    plutil -insert token -string "$token" "$plan"
    plutil -convert json "$plan"
    "$stage/update-helper" --apply-update "$plan" </dev/null >/dev/null 2>&1 &
    helper_pid=$!
    for ((i=0; i<50; i++)); do
        if [ -f "$stage/ready" ]; then break; fi
        if ! kill -0 "$helper_pid" 2>/dev/null; then exit 1; fi
        sleep 0.1
    done
    if [ ! -f "$stage/ready" ]; then kill "$helper_pid" 2>/dev/null || true; exit 1; fi
    trap - EXIT # The helper owns rollback and cleanup after this script exits.
fi
rm -rf "$TICKFIN_APP_PATH"
printf 'Installed: %s\n' "$target"
