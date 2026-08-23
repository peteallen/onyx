#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "$repo_root/scripts/codex-runtime-common.sh"
check_root="$(/usr/bin/mktemp -d "$repo_root/dist-check.XXXXXX")"
app_path="$check_root/Onyx Packaging Check.app"
export ONYX_CODEX_RUNTIME_CACHE_DIR="${ONYX_CODEX_RUNTIME_CACHE_DIR:-$repo_root/.artifacts/codex-runtime}"

cleanup() {
  local exit_code=$?
  /bin/rm -rf -- "$check_root"
  return $exit_code
}
trap cleanup EXIT

codex_runtime_require_manifest
native_architecture="$(/usr/bin/uname -m)"
native_archive="$(codex_runtime_archive_for_architecture "$native_architecture")"
[[ -f "$native_archive" ]] || {
  print -u2 -- "check-package-app: missing pinned runtime archive; run scripts/fetch-codex-runtime.sh --architectures native"
  exit 1
}

# Packaging must fail before touching the destination when the explicit
# runtime input is absent or damaged.
missing_runtime_archive="$check_root/missing-runtime.tar.gz"
/bin/mkdir -p "$app_path"
/usr/bin/touch "$app_path/preserved-on-runtime-failure"
if ONYX_CODEX_RUNTIME_ARCHIVE_ARM64="$missing_runtime_archive" \
   ONYX_CODEX_RUNTIME_ARCHIVE_X86_64="$missing_runtime_archive" \
   "$repo_root/scripts/package-app.sh" debug "$app_path" \
     --bundle-id "app.onyx.packaging-check" >/dev/null 2>&1; then
  print -u2 -- "check-package-app: missing runtime unexpectedly succeeded"
  exit 1
fi
[[ -f "$app_path/preserved-on-runtime-failure" ]] || {
  print -u2 -- "check-package-app: runtime failure changed the destination"
  exit 1
}
/bin/rm -f -- "$app_path/preserved-on-runtime-failure"

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
[[ "$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw -o - \
  "$info_plist")" == *"local model servers"* ]]

runtime_target="$(codex_runtime_target_for_architecture "$native_architecture")"
runtime_package="$app_path/Contents/Helpers/CodexRuntime/$runtime_target"
codex_runtime_verify_installed_package "$runtime_package" "$native_architecture"
[[ "$(/usr/bin/plutil -extract version raw -o - "$runtime_package/codex-package.json")" == \
  "$(codex_runtime_manifest_value version)" ]]
[[ -f "$runtime_package/LICENSE" && -f "$runtime_package/NOTICE" ]]
runtime_targets=("$app_path/Contents/Helpers/CodexRuntime"/*(N:t))
[[ "${(j: :)runtime_targets}" == "$runtime_target" ]]

# Exercise the packaged app-server itself against a clean private home. This
# catches a valid-looking archive that cannot initialize from its final bundle
# location, and proves inherited official-Codex state remains untouched.
codex_runtime_probe_installed_package "$runtime_package"
ONYX_BUNDLED_CODEX_APP_PATH="$app_path" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/module-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$repo_root/.build/swiftpm-module-cache}" \
  /usr/bin/swift test --disable-sandbox --package-path "$repo_root" \
    --filter CodexBundledRuntimeLiveTests

# The explicit archive override is authoritative and checksum-gated. A
# same-size corruption must fail rather than falling back to the cache.
corrupt_archive="$check_root/corrupt-runtime.tar.gz"
/bin/cp "$native_archive" "$corrupt_archive"
/usr/bin/printf '\000' | /bin/dd of="$corrupt_archive" bs=1 seek=32 conv=notrunc >/dev/null 2>&1
corrupt_app="$check_root/Corrupt Runtime Check.app"
if ONYX_CODEX_RUNTIME_ARCHIVE_ARM64="$corrupt_archive" \
   ONYX_CODEX_RUNTIME_ARCHIVE_X86_64="$corrupt_archive" \
   "$repo_root/scripts/package-app.sh" debug "$corrupt_app" \
     --bundle-id "app.onyx.corrupt-runtime-check" >/dev/null 2>&1; then
  print -u2 -- "check-package-app: corrupt runtime unexpectedly succeeded"
  exit 1
fi
[[ ! -e "$corrupt_app" ]] || {
  print -u2 -- "check-package-app: corrupt runtime left a package destination"
  exit 1
}

atomic_swap_root="$check_root/atomic-swap"
/bin/mkdir -p "$atomic_swap_root/existing" "$atomic_swap_root/replacement"
/usr/bin/printf 'old\n' > "$atomic_swap_root/existing/value"
/usr/bin/printf 'new\n' > "$atomic_swap_root/replacement/value"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/module-cache}" \
  SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$repo_root/.build/swiftpm-module-cache}" \
  /usr/bin/swift "$repo_root/scripts/atomic-swap.swift" \
  "$atomic_swap_root/existing" "$atomic_swap_root/replacement"
[[ "$(<"$atomic_swap_root/existing/value")" == "new" ]]
[[ "$(<"$atomic_swap_root/replacement/value")" == "old" ]]

print -- "Packaging checks passed: $app_path"
