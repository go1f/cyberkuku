#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$1"
identity="${CYBERKUKU_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -f "$project_root/.local/signing/identity.sha1" ]]; then identity="$(cat "$project_root/.local/signing/identity.sha1")"; fi
identity="${identity:--}"
requirement='=designated => identifier "com.kojyufu.cyberkuku"'
if [[ "$identity" != - ]]; then requirement="$requirement and certificate leaf = H\"$identity\""; fi
if [[ -f "$app_path/Contents/Helpers/CyberKukuUpdateInstaller" ]]; then
  codesign --force --sign "$identity" --timestamp=none --options runtime "$app_path/Contents/Helpers/CyberKukuUpdateInstaller"
fi
codesign --force --sign "$identity" --timestamp=none --options runtime \
  --identifier com.kojyufu.cyberkuku --requirements "$requirement" \
  --entitlements "$project_root/App/Entitlements.plist" "$app_path"
codesign --verify --deep --strict "$app_path"
