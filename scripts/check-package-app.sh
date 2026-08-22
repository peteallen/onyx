#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
check_root="$(/usr/bin/mktemp -d "$repo_root/dist-check.XXXXXX")"
app_path="$check_root/Onyx Packaging Check.app"

cleanup() {
  local exit_code=$?
  /bin/rm -rf -- "$check_root"
  return $exit_code
}
trap cleanup EXIT

# A rejected invocation must not disturb an existing destination.
/bin/mkdir -p "$app_path"
/usr/bin/touch "$app_path/preserved-on-failure"
if "$repo_root/scripts/package-app.sh" debug "$app_path" \
  --bundle-id "not-a-bundle-id" >/dev/null 2>&1; then
  print -u2 -- "check-package-app: invalid identity unexpectedly succeeded"
  exit 1
fi
[[ -f "$app_path/preserved-on-failure" ]] || {
  print -u2 -- "check-package-app: failed invocation changed the destination"
  exit 1
}

"$repo_root/scripts/package-app.sh" debug "$app_path" \
  --display-name "Onyx Packaging Check" \
  --bundle-id "app.onyx.packaging-check"

info_plist="$app_path/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$info_plist")" == \
  "Onyx Packaging Check" ]]
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")" == \
  "app.onyx.packaging-check" ]]
[[ ! -e "$app_path/preserved-on-failure" ]]
[[ -f "$app_path/Contents/Resources/Onyx.icns" ]]
/usr/bin/plutil -lint "$info_plist" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

print -- "Packaging checks passed: $app_path"
