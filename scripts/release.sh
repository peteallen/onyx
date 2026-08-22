#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
version=""
output_dir="$repo_root/dist-release"
build_number="${ONYX_BUILD_NUMBER:-}"
display_name="${ONYX_APP_DISPLAY_NAME:-Onyx}"
bundle_identifier="${ONYX_BUNDLE_IDENTIFIER:-app.onyx.agent}"
volume_name=""
signing_identity="${ONYX_CODESIGN_IDENTITY:-}"
architectures="${ONYX_ARCHITECTURES:-universal}"
overwrite=0

usage() {
  cat <<'EOF'
Build and verify a distributable Onyx DMG.

Usage:
  scripts/release.sh VERSION [OUTPUT_DIR] [options]

Options:
  --build-number NUMBER          CFBundleVersion. Defaults to a UTC timestamp.
  --display-name NAME            Application display name. Defaults to Onyx.
  --bundle-id IDENTIFIER         Application bundle identifier.
  --volume-name NAME             Mounted DMG volume name. Defaults to "Onyx VERSION".
  --signing-identity IDENTITY    Developer ID Application identity.
  --architectures MODE           universal (default) or native.
  --overwrite                    Replace matching existing release artifacts.
  -h, --help                     Show this help.

Unsigned local release:
  scripts/release.sh 0.1.0

Developer ID signed and notarized release:
  ONYX_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
  ONYX_NOTARIZE=1 ONYX_NOTARY_PROFILE=onyx-notary \
  scripts/release.sh 0.1.0

See scripts/create-dmg.sh --help for supported notarization credentials.
EOF
}

die() {
  print -u2 -- "release: $*"
  exit 1
}

require_value() {
  (( $# >= 2 )) || die "$1 requires a value"
  [[ -n "$2" ]] || die "$1 requires a non-empty value"
}

positional=()
while (( $# > 0 )); do
  case "$1" in
    --build-number)
      require_value "$1" "${2:-}"
      build_number="$2"
      shift 2
      ;;
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
    --volume-name)
      require_value "$1" "${2:-}"
      volume_name="$2"
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
    --overwrite)
      overwrite=1
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

(( ${#positional[@]} >= 1 && ${#positional[@]} <= 2 )) || \
  die "expected VERSION and an optional OUTPUT_DIR"
version="${positional[1]}"
if (( ${#positional[@]} == 2 )); then
  output_dir="${positional[2]}"
fi

[[ "$version" =~ '^[0-9]+[.][0-9]+[.][0-9]+$' ]] || \
  die "VERSION must contain exactly three numeric components (for example, 0.1.0)"
[[ -n "$build_number" ]] || build_number="$(/bin/date -u +%Y%m%d%H%M)"
[[ "$build_number" =~ '^[0-9]+([.][0-9]+){0,2}$' ]] || \
  die "build number must contain one to three numeric components"
[[ "$architectures" == "native" || "$architectures" == "universal" ]] || \
  die "architectures must be native or universal"
[[ -n "$volume_name" ]] || volume_name="$display_name $version"

[[ "$output_dir" == /* ]] || output_dir="$PWD/$output_dir"
output_dir="${output_dir:A}"
/bin/mkdir -p "$output_dir"

dmg_basename="Onyx-$version-macOS.dmg"
dmg_path="$output_dir/$dmg_basename"
checksum_path="$dmg_path.sha256"
if (( overwrite == 0 )) && [[ -e "$dmg_path" || -e "$checksum_path" ]]; then
  die "release artifact exists; pass --overwrite to replace it: $dmg_path"
fi

staging_root="$(/usr/bin/mktemp -d "$output_dir/.onyx-release.XXXXXX")"
app_path="$staging_root/Onyx.app"
cleanup() {
  local exit_code=$?
  /bin/rm -rf -- "$staging_root"
  return $exit_code
}
trap cleanup EXIT

package_arguments=(
  release
  "$app_path"
  --display-name "$display_name"
  --bundle-id "$bundle_identifier"
  --version "$version"
  --build-number "$build_number"
  --architectures "$architectures"
)
if [[ -n "$signing_identity" ]]; then
  package_arguments+=(--signing-identity "$signing_identity")
fi
"$repo_root/scripts/package-app.sh" "${package_arguments[@]}"

dmg_arguments=(
  "$app_path"
  "$dmg_path"
  --volume-name "$volume_name"
)
if [[ -n "$signing_identity" ]]; then
  dmg_arguments+=(--signing-identity "$signing_identity")
fi
if (( overwrite == 1 )); then
  dmg_arguments+=(--overwrite)
fi
"$repo_root/scripts/create-dmg.sh" "${dmg_arguments[@]}"

checksum_staging="$staging_root/$dmg_basename.sha256"
(
  cd "$output_dir"
  /usr/bin/shasum -a 256 "$dmg_basename" > "$checksum_staging"
)
if [[ -e "$checksum_path" ]]; then
  /bin/rm -f -- "$checksum_path"
fi
/bin/mv -- "$checksum_staging" "$checksum_path"

verification_arguments=(
  "$dmg_path"
  --app-name "Onyx.app"
  --bundle-id "$bundle_identifier"
  --version "$version"
  --build-number "$build_number"
)
if [[ "${ONYX_NOTARIZE:-0}" == "1" || "${ONYX_NOTARIZE:-0}" == "true" ]]; then
  verification_arguments+=(--require-notarized)
fi
if [[ "$architectures" == "universal" ]]; then
  verification_arguments+=(--require-universal)
fi
"$repo_root/scripts/verify-dmg.sh" "${verification_arguments[@]}"

print -- "Release artifacts are ready:"
print -- "  $dmg_path"
print -- "  $checksum_path"
