#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/Music Island Lyrics.app"
binary="$project_dir/.build/release/MusicIslandLyrics"
module_cache="$project_dir/.build/module-cache"

cd "$project_dir"
env CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift build --disable-sandbox -c release

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary" "$app_dir/Contents/MacOS/MusicIslandLyrics"
cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"

codesign --force --deep --sign - \
    --entitlements "$project_dir/Support/MusicIslandLyrics.entitlements" \
    "$app_dir"

echo "$app_dir"
