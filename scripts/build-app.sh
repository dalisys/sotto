#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
configuration="${1:-release}"
task_cache="${TMPDIR:-/tmp}/sotto-swift-cache"
mkdir -p "$task_cache/clang" "$task_cache/swift"
export CLANG_MODULE_CACHE_PATH="$task_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_cache/swift"
build_options=(--disable-sandbox --manifest-cache local -c "$configuration")
if [ "$configuration" = release ]; then
    build_options+=(-debug-info-format none)
fi
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
app_dir="${SOTTO_APP_OUTPUT:-$project_dir/dist/Sotto.app}"
# LaunchServices cannot reliably open an application beneath a control-character path.
if [[ "$app_dir" =~ [[:cntrl:]] ]]; then
    app_dir="${TMPDIR:-/tmp}/Sotto-build/Sotto.app"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Dependency resources may retain read-only source permissions after packaging.
# Make our generated output writable so rebuilding the same bundle succeeds.
chmod -R u+w "$app_dir/Contents/Resources"
cp "$binary_dir/Sotto" "$app_dir/Contents/MacOS/Sotto"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/FluidAudio-LICENSE.txt "$app_dir/Contents/Resources/FluidAudio-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/SottoTest.wav "$app_dir/Contents/Resources/SottoTest.wav"
cp Resources/SottoIcon.png "$app_dir/Contents/Resources/SottoIcon.png"
cp Resources/SottoMenuTemplate.png "$app_dir/Contents/Resources/SottoMenuTemplate.png"
if [ -f Resources/Sotto.icns ]; then
    cp Resources/Sotto.icns "$app_dir/Contents/Resources/Sotto.icns"
fi
# SwiftPM's Bundle.module resolves dependency resources from the app resource directory.
for resource_bundle in "$binary_dir"/*.bundle; do
    [ -d "$resource_bundle" ] || continue
    ditto "$resource_bundle" "$app_dir/Contents/Resources/$(basename "$resource_bundle")"
done
codesign --force --sign - --identifier com.sotto.dictation --options runtime \
    --entitlements Resources/Sotto.entitlements "$app_dir"
codesign --verify --strict "$app_dir"
printf '\nBuilt %s\n' "$app_dir"
