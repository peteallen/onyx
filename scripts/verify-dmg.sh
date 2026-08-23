#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "$repo_root/scripts/codex-runtime-common.sh"

dmg_path=""
expected_app_name=""
expected_bundle_identifier=""
expected_version=""
expected_build_number=""
require_notarized=0
require_universal=0

usage() {
  cat <<'EOF'
Verify an Onyx release disk image without installing or launching the app.

Usage:
  scripts/verify-dmg.sh DMG_PATH [options]

Options:
  --app-name NAME             Expected top-level application bundle name.
  --bundle-id IDENTIFIER      Expected CFBundleIdentifier.
  --version VERSION           Expected CFBundleShortVersionString.
  --build-number NUMBER       Expected CFBundleVersion.
  --require-universal         Require arm64 and x86_64 executable slices.
  --require-notarized         Require a stapled ticket and Gatekeeper acceptance.
  -h, --help                  Show this help.
EOF
}

die() {
  print -u2 -- "verify-dmg: $*"
  exit 1
}

require_value() {
  (( $# >= 2 )) || die "$1 requires a value"
  [[ -n "$2" ]] || die "$1 requires a non-empty value"
}

positional=()
while (( $# > 0 )); do
  case "$1" in
    --app-name)
      require_value "$1" "${2:-}"
      expected_app_name="$2"
      shift 2
      ;;
    --bundle-id)
      require_value "$1" "${2:-}"
      expected_bundle_identifier="$2"
      shift 2
      ;;
    --version)
      require_value "$1" "${2:-}"
      expected_version="$2"
      shift 2
      ;;
    --build-number)
      require_value "$1" "${2:-}"
      expected_build_number="$2"
      shift 2
      ;;
    --require-notarized)
      require_notarized=1
      shift
      ;;
    --require-universal)
      require_universal=1
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

(( ${#positional[@]} == 1 )) || die "expected exactly one DMG_PATH"
dmg_path="${positional[1]}"
[[ "$dmg_path" == /* ]] || dmg_path="$PWD/$dmg_path"
dmg_path="${dmg_path:A}"

[[ -f "$dmg_path" ]] || die "disk image does not exist: $dmg_path"
[[ "${dmg_path:t}" == *.dmg ]] || die "DMG_PATH must end in .dmg"

print -- "Verifying disk image structure…"
/usr/bin/hdiutil verify "$dmg_path" >/dev/null

if /usr/bin/codesign -dv "$dmg_path" >/dev/null 2>&1; then
  /usr/bin/codesign --verify --verbose=2 "$dmg_path"
  image_signature="signed"
else
  image_signature="unsigned"
fi

if (( require_notarized == 1 )); then
  /usr/bin/xcrun stapler validate "$dmg_path"
  /usr/sbin/spctl --assess --type open --context context:primary-signature \
    --verbose=2 "$dmg_path"
fi

mount_point="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/onyx-dmg-verify.XXXXXX")"
attached=0
cleanup() {
  local exit_code=$?
  if (( attached == 1 )); then
    /usr/bin/hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || \
      /usr/bin/hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$mount_point"
  return $exit_code
}
trap cleanup EXIT

/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen \
  -mountpoint "$mount_point" "$dmg_path" >/dev/null
attached=1

app_candidates=("$mount_point"/*.app(N))
(( ${#app_candidates[@]} == 1 )) || \
  die "expected exactly one top-level .app bundle, found ${#app_candidates[@]}"
app_path="${app_candidates[1]}"

if [[ -n "$expected_app_name" && "${app_path:t}" != "$expected_app_name" ]]; then
  die "expected app '$expected_app_name', found '${app_path:t}'"
fi

applications_link="$mount_point/Applications"
[[ -L "$applications_link" ]] || die "disk image is missing the Applications shortcut"
[[ "$(/usr/bin/readlink "$applications_link")" == "/Applications" ]] || \
  die "Applications shortcut does not target /Applications"

top_level_entries=("$mount_point"/*(DN:t))
expected_top_level_entries=("${app_path:t}" "Applications")
top_level_entries=("${(@on)top_level_entries}")
expected_top_level_entries=("${(@on)expected_top_level_entries}")
[[ "${(j:\n:)top_level_entries}" == "${(j:\n:)expected_top_level_entries}" ]] ||
  die "disk image contains an unexpected top-level payload: ${(j:, :)top_level_entries}"

info_plist="$app_path/Contents/Info.plist"
executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist" \
  2>/dev/null || true)"
[[ -n "$executable_name" ]] || die "app has no CFBundleExecutable"
executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -x "$executable_path" ]] || \
  die "app executable is missing or not executable"
/usr/bin/plutil -lint "$info_plist" >/dev/null
executable_architectures="$(/usr/bin/lipo -archs "$executable_path")"
if (( require_universal == 1 )); then
  [[ " $executable_architectures " == *" arm64 "* && \
     " $executable_architectures " == *" x86_64 "* ]] || \
    die "app is not universal arm64 + x86_64: $executable_architectures"
fi

codex_runtime_require_manifest
runtime_root="$app_path/Contents/Helpers/CodexRuntime"
[[ -d "$runtime_root" && ! -L "$runtime_root" ]] ||
  die "app is missing the pinned Codex runtime"
expected_runtime_architectures=()
if (( require_universal == 1 )); then
  expected_runtime_architectures=(arm64 x86_64)
else
  [[ " $executable_architectures " == *" arm64 "* ]] &&
    expected_runtime_architectures+=(arm64)
  [[ " $executable_architectures " == *" x86_64 "* ]] &&
    expected_runtime_architectures+=(x86_64)
fi
(( ${#expected_runtime_architectures[@]} > 0 )) ||
  die "app has no supported Codex runtime architecture: $executable_architectures"

expected_runtime_targets=()
for runtime_architecture in "${expected_runtime_architectures[@]}"; do
  runtime_target="$(codex_runtime_target_for_architecture "$runtime_architecture")"
  expected_runtime_targets+=("$runtime_target")
  codex_runtime_verify_installed_package \
    "$runtime_root/$runtime_target" "$runtime_architecture"
done
installed_runtime_targets=("$runtime_root"/*(N:t))
[[ "${(j:\n:)installed_runtime_targets}" == "${(j:\n:)expected_runtime_targets}" ]] ||
  die "Codex runtime targets do not match app architectures"

# Verify the outer signature only after reporting any nested helper problem.
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
if (( require_notarized == 1 )); then
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
fi

# Only execute the mounted helper after its complete package, the outer app,
# and (for public releases) Gatekeeper acceptance have all been established.
native_architecture="$(/usr/bin/uname -m)"
if (( ${expected_runtime_architectures[(Ie)$native_architecture]} )); then
  native_runtime_target="$(codex_runtime_target_for_architecture "$native_architecture")"
  codex_runtime_probe_installed_package "$runtime_root/$native_runtime_target"
fi

verify_plist_value() {
  local key="$1"
  local expected="$2"
  local label="$3"
  [[ -n "$expected" ]] || return 0
  local actual
  actual="$(/usr/bin/plutil -extract "$key" raw -o - "$info_plist")"
  [[ "$actual" == "$expected" ]] || \
    die "$label mismatch: expected '$expected', found '$actual'"
}

verify_plist_value CFBundleIdentifier "$expected_bundle_identifier" "bundle identifier"
verify_plist_value CFBundleShortVersionString "$expected_version" "version"
verify_plist_value CFBundleVersion "$expected_build_number" "build number"

print -- "DMG verification passed: $dmg_path"
print -- "Application: ${app_path:t}"
print -- "Architectures: $executable_architectures"
print -- "Disk image signature: $image_signature"
if (( require_notarized == 1 )); then
  print -- "Notarization: stapled and accepted by Gatekeeper"
fi
