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
notarize_mode="${ONYX_NOTARIZE:-0}"
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
  --notarize                     Require DMG notarization (uses configured credentials).
  --no-notarize                  Disable notarization, even when ONYX_NOTARIZE is set.
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
    --notarize)
      notarize_mode=1
      shift
      ;;
    --no-notarize)
      notarize_mode=0
      shift
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
case "$notarize_mode" in
  1|true)
    notarize_mode=1
    ;;
  0|false)
    notarize_mode=0
    ;;
  *)
    die "ONYX_NOTARIZE must be 0, 1, false, or true"
    ;;
esac
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
staged_artifact_dir="$staging_root/artifacts"
staged_dmg_path="$staged_artifact_dir/$dmg_basename"
staged_checksum_path="$staged_artifact_dir/$dmg_basename.sha256"
previous_dmg="$staging_root/previous.dmg"
previous_checksum="$staging_root/previous.dmg.sha256"
publish_in_progress=0
had_previous_dmg=0
had_previous_checksum=0
published_dmg=0
published_checksum=0

rollback_release_pair() {
  local rollback_failed=0

  if (( published_dmg == 1 )); then
    /bin/rm -f -- "$dmg_path" || rollback_failed=1
  fi
  if (( published_checksum == 1 )); then
    /bin/rm -f -- "$checksum_path" || rollback_failed=1
  fi
  if (( had_previous_dmg == 1 )); then
    /bin/mv -- "$previous_dmg" "$dmg_path" || rollback_failed=1
  fi
  if (( had_previous_checksum == 1 )); then
    /bin/mv -- "$previous_checksum" "$checksum_path" || rollback_failed=1
  fi

  return $rollback_failed
}

cleanup() {
  local exit_code=$?
  if (( publish_in_progress == 1 )); then
    rollback_release_pair ||
      print -u2 -- "release: warning: could not fully restore the previous artifact pair"
  fi
  /bin/rm -rf -- "$staging_root"
  return $exit_code
}
trap cleanup EXIT
/bin/mkdir -p "$staged_artifact_dir"

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
  "$staged_dmg_path"
  --volume-name "$volume_name"
)
if [[ -n "$signing_identity" ]]; then
  dmg_arguments+=(--signing-identity "$signing_identity")
fi
ONYX_NOTARIZE="$notarize_mode" \
  "$repo_root/scripts/create-dmg.sh" "${dmg_arguments[@]}"

(
  cd "$staged_artifact_dir"
  /usr/bin/shasum -a 256 "$dmg_basename" > "$staged_checksum_path"
  /usr/bin/shasum -a 256 -c "${staged_checksum_path:t}"
)

verification_arguments=(
  "$staged_dmg_path"
  --app-name "Onyx.app"
  --bundle-id "$bundle_identifier"
  --version "$version"
  --build-number "$build_number"
)
if (( notarize_mode == 1 )); then
  verification_arguments+=(--require-notarized)
fi
if [[ "$architectures" == "universal" ]]; then
  verification_arguments+=(--require-universal)
fi
"$repo_root/scripts/verify-dmg.sh" "${verification_arguments[@]}"

if (( overwrite == 0 )) && [[ -e "$dmg_path" || -e "$checksum_path" ]]; then
  die "release artifact appeared while building; rerun with --overwrite to replace it: $dmg_path"
fi
if [[ -L "$dmg_path" || -L "$checksum_path" ]]; then
  die "refusing to replace a symbolic-link release artifact"
fi
if [[ -e "$dmg_path" && ! -f "$dmg_path" ]] || \
   [[ -e "$checksum_path" && ! -f "$checksum_path" ]]; then
  die "existing release artifact is not a regular file"
fi

# Publish the verified DMG and its matching checksum as one recoverable pair.
# Two files cannot be renamed atomically as one POSIX object, so keep rollback
# armed from the first backup move through verification of the published pair.
publish_in_progress=1
if [[ -e "$dmg_path" ]]; then
  /bin/mv -- "$dmg_path" "$previous_dmg" ||
    die "could not preserve the existing disk image"
  had_previous_dmg=1
fi
if [[ -e "$checksum_path" ]]; then
  /bin/mv -- "$checksum_path" "$previous_checksum" ||
    die "could not preserve the existing checksum"
  had_previous_checksum=1
fi

/bin/mv -- "$staged_dmg_path" "$dmg_path" ||
  die "could not publish the verified disk image"
published_dmg=1
/bin/mv -- "$staged_checksum_path" "$checksum_path" ||
  die "could not publish the verified checksum"
published_checksum=1

(cd "$output_dir" && /usr/bin/shasum -a 256 -c "${checksum_path:t}") ||
  die "published release artifact checksum verification failed"
publish_in_progress=0

print -- "Release artifacts are ready:"
print -- "  $dmg_path"
print -- "  $checksum_path"
