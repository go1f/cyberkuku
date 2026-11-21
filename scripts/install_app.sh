#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_app="${1:-$project_root/release/CyberKuku.app}"
destination='/Applications/CyberKuku.app'
codesign --verify --deep --strict "$source_app"
if [[ -d "$destination" ]]; then
  mkdir -p "$project_root/.local/installed-backups"
  mv "$destination" "$project_root/.local/installed-backups/CyberKuku-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$source_app" "$destination"
codesign --verify --deep --strict "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
mdimport "$destination" || true
printf 'Installed: %s\n' "$destination"
