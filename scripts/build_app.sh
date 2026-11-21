#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build --scratch-path "${CYBERKUKU_BUILD_PATH:-.build}" -c release --build-system native --product CyberKuku
swift build --scratch-path "${CYBERKUKU_BUILD_PATH:-.build}" -c release --build-system native --product CyberKukuUpdateInstaller
binary_dir="$(swift build --scratch-path "${CYBERKUKU_BUILD_PATH:-.build}" -c release --build-system native --show-bin-path)"
destination="$project_root/dist/CyberKuku.app"
mkdir -p "$project_root/dist"
staging="$(mktemp -d "$project_root/dist/.build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app_path="$staging/CyberKuku.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/CyberKuku" "$app_path/Contents/MacOS/CyberKuku"
mkdir -p "$app_path/Contents/Helpers"
cp "$binary_dir/CyberKukuUpdateInstaller" "$app_path/Contents/Helpers/CyberKukuUpdateInstaller"
cp "$project_root/App/Info.plist" "$app_path/Contents/Info.plist"
iconset_path="$project_root/.local/icons/CyberKuku.iconset"
swift "$project_root/scripts/build_icons.swift" "$project_root/App/Assets/Companion.png" "$iconset_path" light
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/CyberKuku.icns"
for appearance in Light Dark; do
  variant_iconset="$project_root/.local/icons/CyberKuku${appearance}.iconset"
  swift "$project_root/scripts/build_icons.swift" "$project_root/App/Assets/Companion.png" "$variant_iconset" light
  iconutil -c icns "$variant_iconset" -o "$app_path/Contents/Resources/CyberKuku${appearance}.icns"
done
cp "$project_root/App/Assets/SeatedMascot.svg" "$app_path/Contents/Resources/SeatedMascot.svg"
cp "$project_root/App/Assets/Companion.png" "$app_path/Contents/Resources/Companion.png"
cp "$project_root/App/Assets/StatusIcon.png" "$app_path/Contents/Resources/StatusIcon.png"
if [[ -f "$project_root/.local/pose-backend.json" ]]; then
  cp "$project_root/.local/pose-backend.json" "$app_path/Contents/Resources/pose-backend.json"
  cp "$project_root/pose-worker/pose_worker.py" "$app_path/Contents/Resources/pose_worker.py"
  cp "$project_root/.local/models/pose_landmarker_full.task" "$app_path/Contents/Resources/pose_landmarker_full.task"
fi
zsh "$project_root/scripts/sign_app.sh" "$app_path"
if [[ -d "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app_path" "$destination"; then
  if [[ -d "$staging/previous.app" ]]; then mv "$staging/previous.app" "$destination"; fi
  exit 1
fi
app_path="$destination"
printf 'Built: %s\n' "$app_path"
if [[ "${1:-}" == "--run" ]]; then
  open "$app_path"
elif [[ "${1:-}" == "--demo" ]]; then
  open "$app_path" --args --demo
fi
