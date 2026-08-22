#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
configuration="debug"
app_dir=""
display_name="${ONYX_APP_DISPLAY_NAME:-}"
bundle_identifier="${ONYX_BUNDLE_IDENTIFIER:-}"
short_version="${ONYX_APP_VERSION:-}"
build_number="${ONYX_BUILD_NUMBER:-}"
signing_identity="${ONYX_CODESIGN_IDENTITY:-}"
architectures="${ONYX_ARCHITECTURES:-native}"
allow_running_overwrite=0

usage() {
  cat <<'EOF'
Build, package, sign, and verify Onyx.

Usage:
  scripts/package-app.sh [debug|release] [APP_PATH] [options]

Options:
  --display-name NAME            Name shown by macOS.
  --bundle-id IDENTIFIER         Bundle identifier (for example, dev.example.onyx.preview).
  --version VERSION              CFBundleShortVersionString.
  --build-number NUMBER          CFBundleVersion.
  --signing-identity IDENTITY    Developer ID Application identity. Defaults to ad hoc.
  --architectures MODE           native or universal (arm64 + x86_64).
  --allow-running-overwrite      Replace APP_PATH even when that exact app is running.
  -h, --help                     Show this help.

Environment equivalents:
  ONYX_APP_DISPLAY_NAME, ONYX_BUNDLE_IDENTIFIER, ONYX_APP_VERSION,
  ONYX_BUILD_NUMBER, ONYX_CODESIGN_IDENTITY, ONYX_ARCHITECTURES

The positional form `scripts/package-app.sh debug [APP_PATH]` remains supported.
The script never launches or stops an application.
EOF
}

die() {
  print -u2 -- "package-app: $*"
  exit 1
}

require_value() {
  (( $# >= 2 )) || die "$1 requires a value"
  [[ -n "$2" ]] || die "$1 requires a non-empty value"
}

positional=()
while (( $# > 0 )); do
  case "$1" in
    --display-name)
      require_value "$1" "${2:-}"
      display_name="$2"
      shift 2
      ;;
    --bundle-id)
      require_value "$1" "${2:-}"
      bundle_identifier="$2"
      shift 2
      ;;
    --version)
      require_value "$1" "${2:-}"
      short_version="$2"
      shift 2
      ;;
    --build-number)
      require_value "$1" "${2:-}"
      build_number="$2"
      shift 2
      ;;
    --signing-identity)
      require_value "$1" "${2:-}"
      signing_identity="$2"
      shift 2
      ;;
    --architectures)
      require_value "$1" "${2:-}"
      architectures="$2"
      shift 2
      ;;
    --allow-running-overwrite)
      allow_running_overwrite=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

(( ${#positional[@]} <= 2 )) || die "expected at most a configuration and APP_PATH"
if (( ${#positional[@]} >= 1 )); then
  configuration="${positional[1]}"
fi
[[ "$configuration" == "debug" || "$configuration" == "release" ]] || \
  die "configuration must be debug or release (got: $configuration)"

if (( ${#positional[@]} == 2 )); then
  app_dir="${positional[2]}"
else
  app_dir="$repo_root/dist/Onyx.app"
fi
if [[ "$app_dir" != /* ]]; then
  app_dir="$repo_root/$app_dir"
fi
app_dir="${app_dir:A}"
[[ "${app_dir:t}" == *.app ]] || die "APP_PATH must end in .app"
[[ "$app_dir" != "/" ]] || die "refusing to package at filesystem root"

info_template="$repo_root/support/Info.plist"
[[ -f "$info_template" ]] || die "missing Info.plist template: $info_template"
icon_file="$repo_root/support/Onyx.icns"
[[ -f "$icon_file" ]] || die "missing app icon: $icon_file"

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$info_template"
}

[[ -n "$display_name" ]] || display_name="$(plist_value CFBundleDisplayName)"
[[ -n "$bundle_identifier" ]] || bundle_identifier="$(plist_value CFBundleIdentifier)"
[[ -n "$short_version" ]] || short_version="$(plist_value CFBundleShortVersionString)"
[[ -n "$build_number" ]] || build_number="$(plist_value CFBundleVersion)"
[[ -n "$signing_identity" ]] || signing_identity="-"

[[ "$display_name" != *$'\n'* && "$display_name" != *$'\r'* ]] || \
  die "display name cannot contain a newline"
[[ "$bundle_identifier" =~ '^[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$' ]] || \
  die "invalid bundle identifier: $bundle_identifier"
[[ "$bundle_identifier" == *.* ]] || \
  die "bundle identifier must contain at least one dot: $bundle_identifier"
[[ "$short_version" =~ '^[0-9]+([.][0-9]+){0,2}$' ]] || \
  die "version must contain one to three numeric components: $short_version"
[[ "$build_number" =~ '^[0-9]+([.][0-9]+){0,2}$' ]] || \
  die "build number must contain one to three numeric components: $build_number"
[[ "$architectures" == "native" || "$architectures" == "universal" ]] || \
  die "architectures must be native or universal (got: $architectures)"
[[ "$signing_identity" != *$'\n'* && "$signing_identity" != *$'\r'* ]] || \
  die "signing identity cannot contain a newline"

target_executable="$app_dir/Contents/MacOS/Onyx"
if [[ -f "$app_dir/Contents/Info.plist" ]]; then
  existing_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - \
    "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$existing_executable" ]]; then
    target_executable="$app_dir/Contents/MacOS/$existing_executable"
  fi
fi

running_pids=""
if [[ -f "$target_executable" && -x /usr/sbin/lsof ]]; then
  running_pids="$(/usr/sbin/lsof -a -d txt -t -- "$target_executable" 2>/dev/null || true)"
fi
if [[ -n "$running_pids" && "$allow_running_overwrite" -ne 1 ]]; then
  running_summary="${running_pids//$'\n'/, }"
  die "target is running (PID ${running_summary}): $app_dir
Quit it first, choose a different APP_PATH, or explicitly pass --allow-running-overwrite."
elif [[ -n "$running_pids" ]]; then
  print -u2 -- "package-app: warning: replacing a running target by explicit request: $app_dir"
fi

print -- "Building Onyx ($configuration, $architectures)…"
# Keep compiler modules within the build tree when the user's global Swift/Clang
# caches are unavailable (for example, in a restricted CI or agent workspace).
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$repo_root/.build/swiftpm-module-cache}"
binary_paths=()
if [[ "$architectures" == "native" ]]; then
  /usr/bin/swift build --disable-sandbox --package-path "$repo_root" -c "$configuration"
  binary_dir="$(/usr/bin/swift build --disable-sandbox --package-path "$repo_root" \
    -c "$configuration" --show-bin-path)"
  binary_paths+=("$binary_dir/Onyx")
else
  for architecture in arm64 x86_64; do
    target_triple="$architecture-apple-macosx15.0"
    scratch_path="$repo_root/.build/package-$configuration-$architecture"
    /usr/bin/swift build --disable-sandbox --package-path "$repo_root" \
      --scratch-path "$scratch_path" --triple "$target_triple" -c "$configuration"
    binary_dir="$(/usr/bin/swift build --disable-sandbox --package-path "$repo_root" \
      --scratch-path "$scratch_path" --triple "$target_triple" -c "$configuration" \
      --show-bin-path)"
    binary_paths+=("$binary_dir/Onyx")
  done
fi
for binary_path in "${binary_paths[@]}"; do
  [[ -x "$binary_path" ]] || die "build completed without executable: $binary_path"
done

parent_dir="${app_dir:h}"
app_basename="${app_dir:t}"
/bin/mkdir -p "$parent_dir"
staging_root="$(/usr/bin/mktemp -d "$parent_dir/.${app_basename}.package.XXXXXX")"
staged_app="$staging_root/$app_basename"
backup_path="$parent_dir/.${app_basename}.backup.$$.$RANDOM"

cleanup() {
  local exit_code=$?
  if [[ -n "${staging_root:-}" && -d "$staging_root" ]]; then
    /bin/rm -rf -- "$staging_root"
  fi
  if [[ -n "${backup_path:-}" && -e "$backup_path" && ! -e "$app_dir" ]]; then
    /bin/mv -- "$backup_path" "$app_dir"
  fi
  return $exit_code
}
trap cleanup EXIT

contents_dir="$staged_app/Contents"
/bin/mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
if [[ "$architectures" == "native" ]]; then
  /usr/bin/install -m 755 "${binary_paths[1]}" "$contents_dir/MacOS/Onyx"
else
  /usr/bin/lipo -create "${binary_paths[@]}" -output "$contents_dir/MacOS/Onyx"
  /bin/chmod 755 "$contents_dir/MacOS/Onyx"
fi
/usr/bin/install -m 644 "$info_template" "$contents_dir/Info.plist"
/usr/bin/install -m 644 "$icon_file" "$contents_dir/Resources/Onyx.icns"
/usr/bin/printf 'APPL????' > "$contents_dir/PkgInfo"

/usr/bin/plutil -replace CFBundleDisplayName -string "$display_name" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$display_name" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$short_version" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$contents_dir/Info.plist"

print -- "Signing and verifying staged app…"
/usr/bin/plutil -lint "$contents_dir/Info.plist" >/dev/null
codesign_arguments=(--force --sign "$signing_identity")
signature_summary="ad hoc"
if [[ "$signing_identity" == "-" ]]; then
  codesign_arguments+=(--timestamp=none)
else
  codesign_arguments+=(--options runtime --timestamp)
  signature_summary="$signing_identity (hardened runtime)"
fi
/usr/bin/codesign "${codesign_arguments[@]}" "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"

[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$contents_dir/Info.plist")" == "$display_name" ]] || \
  die "packaged display name did not verify"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$contents_dir/Info.plist")" == "$bundle_identifier" ]] || \
  die "packaged bundle identifier did not verify"
[[ -x "$contents_dir/MacOS/Onyx" ]] || die "packaged executable is not executable"
[[ -f "$contents_dir/Resources/Onyx.icns" ]] || die "packaged app icon is missing"
if [[ "$architectures" == "universal" ]]; then
  packaged_architectures="$(/usr/bin/lipo -archs "$contents_dir/MacOS/Onyx")"
  [[ " $packaged_architectures " == *" arm64 "* && \
     " $packaged_architectures " == *" x86_64 "* ]] || \
    die "universal executable did not contain arm64 and x86_64: $packaged_architectures"
fi

# Everything that can fail has operated on a sibling staging directory. Keep the
# prior target available for rollback until the verified bundle is in place.
if [[ -e "$app_dir" ]]; then
  [[ ! -e "$backup_path" ]] || die "backup path unexpectedly exists: $backup_path"
  /bin/mv -- "$app_dir" "$backup_path"
fi
if ! /bin/mv -- "$staged_app" "$app_dir"; then
  if [[ -e "$backup_path" && ! -e "$app_dir" ]]; then
    /bin/mv -- "$backup_path" "$app_dir"
  fi
  die "could not move the verified app into place"
fi

if [[ -e "$backup_path" ]]; then
  /bin/rm -rf -- "$backup_path"
fi

print -- "Packaged: $app_dir"
print -- "Display name: $display_name"
print -- "Bundle ID: $bundle_identifier"
print -- "Architectures: $(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/Onyx")"
print -- "Signature: $signature_summary (verified)"
