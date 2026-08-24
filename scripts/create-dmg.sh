#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_path=""
dmg_path=""
volume_name=""
signing_identity="${ONYX_CODESIGN_IDENTITY:-}"
notarize="${ONYX_NOTARIZE:-0}"
notary_profile="${ONYX_NOTARY_PROFILE:-}"
overwrite=0

usage() {
  cat <<'EOF'
Create, optionally sign/notarize, and verify a drag-to-Applications disk image.

Usage:
  scripts/create-dmg.sh APP_PATH DMG_PATH [options]

Options:
  --volume-name NAME             Mounted volume name. Defaults to the app display name.
  --signing-identity IDENTITY    Sign the DMG with a Developer ID Application identity.
  --notarize                     Submit the DMG, wait, staple, and verify the ticket.
  --notary-profile PROFILE       notarytool keychain profile (implies --notarize).
  --overwrite                    Replace an existing regular DMG after verification.
  -h, --help                     Show this help.

Environment:
  ONYX_CODESIGN_IDENTITY
  ONYX_NOTARIZE=1
  ONYX_NOTARY_PROFILE

For notarization without a keychain profile, provide either:
  ONYX_NOTARY_KEY_PATH, ONYX_NOTARY_KEY_ID, ONYX_NOTARY_ISSUER_ID
or:
  ONYX_NOTARY_APPLE_ID, ONYX_NOTARY_TEAM_ID, ONYX_NOTARY_PASSWORD

The default output is an unsigned DMG containing an ad-hoc-signed app. The
script never installs, launches, or stops the application.
EOF
}

die() {
  print -u2 -- "create-dmg: $*"
  exit 1
}

require_value() {
  (( $# >= 2 )) || die "$1 requires a value"
  [[ -n "$2" ]] || die "$1 requires a non-empty value"
}

positional=()
while (( $# > 0 )); do
  case "$1" in
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
      notarize=1
      shift
      ;;
    --notary-profile)
      require_value "$1" "${2:-}"
      notary_profile="$2"
      notarize=1
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

(( ${#positional[@]} == 2 )) || die "expected APP_PATH and DMG_PATH"
app_path="${positional[1]}"
dmg_path="${positional[2]}"
[[ "$app_path" == /* ]] || app_path="$PWD/$app_path"
[[ "$dmg_path" == /* ]] || dmg_path="$PWD/$dmg_path"
app_path="${app_path:A}"
dmg_path="${dmg_path:a}"

[[ -d "$app_path" && "${app_path:t}" == *.app ]] || \
  die "APP_PATH must be an existing .app bundle: $app_path"
[[ "${dmg_path:t}" == *.dmg ]] || die "DMG_PATH must end in .dmg"
[[ "$dmg_path" != "/" ]] || die "refusing to write at filesystem root"
case "$notarize" in
  1|true)
    notarize=1
    ;;
  0|false)
    notarize=0
    ;;
  *)
    die "ONYX_NOTARIZE must be 0, 1, false, or true"
    ;;
esac
[[ "$signing_identity" != *$'\n'* && "$signing_identity" != *$'\r'* ]] || \
  die "signing identity cannot contain a newline"

if [[ -L "$dmg_path" ]]; then
  die "refusing to replace a symbolic link: $dmg_path"
fi
if [[ -e "$dmg_path" && ! -f "$dmg_path" ]]; then
  die "existing DMG_PATH is not a regular file: $dmg_path"
fi
if [[ -e "$dmg_path" && "$overwrite" -ne 1 ]]; then
  die "destination exists; pass --overwrite to replace it: $dmg_path"
fi

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || die "app is missing Contents/Info.plist"
/usr/bin/plutil -lint "$info_plist" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$info_plist"
}

display_name="$(plist_value CFBundleDisplayName)"
bundle_identifier="$(plist_value CFBundleIdentifier)"
short_version="$(plist_value CFBundleShortVersionString)"
build_number="$(plist_value CFBundleVersion)"
[[ -n "$volume_name" ]] || volume_name="$display_name"
[[ -n "$volume_name" ]] || die "volume name cannot be empty"
[[ "$volume_name" != */* && "$volume_name" != *:* ]] || \
  die "volume name cannot contain '/' or ':'"
[[ "$volume_name" != *$'\n'* && "$volume_name" != *$'\r'* ]] || \
  die "volume name cannot contain a newline"
(( ${#volume_name} <= 27 )) || \
  die "volume name must be at most 27 characters for HFS+: $volume_name"

if (( notarize == 1 )) && [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
  die "notarization requires --signing-identity or ONYX_CODESIGN_IDENTITY"
fi

parent_dir="${dmg_path:h}"
dmg_basename="${dmg_path:t}"
/bin/mkdir -p "$parent_dir"
staging_root="$(/usr/bin/mktemp -d "$parent_dir/.${dmg_basename}.create.XXXXXX")"
payload_dir="$staging_root/payload"
staged_dmg="$staging_root/$dmg_basename"
backup_path="$parent_dir/.${dmg_basename}.backup.$$.$RANDOM"

cleanup() {
  local exit_code=$?
  if [[ -e "$backup_path" && ! -e "$dmg_path" ]]; then
    /bin/mv -- "$backup_path" "$dmg_path"
  fi
  /bin/rm -rf -- "$staging_root"
  return $exit_code
}
trap cleanup EXIT

/bin/mkdir -p "$payload_dir"
/usr/bin/ditto "$app_path" "$payload_dir/${app_path:t}"
/bin/ln -s /Applications "$payload_dir/Applications"

print -- "Creating compressed disk image…"
hdiutil_output=""
if ! hdiutil_output="$(/usr/bin/hdiutil create -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -volname "$volume_name" -srcfolder "$payload_dir" \
  "$staged_dmg" 2>&1)"; then
  print -u2 -- "$hdiutil_output"
  die "disk image creation failed"
fi

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  print -- "Signing disk image…"
  /usr/bin/codesign --force --sign "$signing_identity" --timestamp "$staged_dmg"
  /usr/bin/codesign --verify --verbose=2 "$staged_dmg"
fi

if (( notarize == 1 )); then
  print -- "Submitting disk image for notarization…"
  if [[ -n "$notary_profile" ]]; then
    notary_arguments=(--keychain-profile "$notary_profile")
  elif [[ -n "${ONYX_NOTARY_KEY_PATH:-}" || -n "${ONYX_NOTARY_KEY_ID:-}" || \
          -n "${ONYX_NOTARY_ISSUER_ID:-}" ]]; then
    [[ -f "${ONYX_NOTARY_KEY_PATH:-}" ]] || \
      die "ONYX_NOTARY_KEY_PATH must reference an App Store Connect API private key"
    [[ -n "${ONYX_NOTARY_KEY_ID:-}" && -n "${ONYX_NOTARY_ISSUER_ID:-}" ]] || \
      die "API-key notarization requires key path, key ID, and issuer ID"
    notary_arguments=(
      --key "$ONYX_NOTARY_KEY_PATH"
      --key-id "$ONYX_NOTARY_KEY_ID"
      --issuer "$ONYX_NOTARY_ISSUER_ID"
    )
  else
    [[ -n "${ONYX_NOTARY_APPLE_ID:-}" && -n "${ONYX_NOTARY_TEAM_ID:-}" && \
       -n "${ONYX_NOTARY_PASSWORD:-}" ]] || \
      die "notarization credentials are incomplete; see --help"
    notary_arguments=(
      --apple-id "$ONYX_NOTARY_APPLE_ID"
      --team-id "$ONYX_NOTARY_TEAM_ID"
      --password "$ONYX_NOTARY_PASSWORD"
    )
  fi
  /usr/bin/xcrun notarytool submit "$staged_dmg" "${notary_arguments[@]}" --wait
  /usr/bin/xcrun stapler staple "$staged_dmg"
  /usr/bin/xcrun stapler validate "$staged_dmg"
fi

verification_arguments=(
  "$staged_dmg"
  --app-name "${app_path:t}"
  --bundle-id "$bundle_identifier"
  --version "$short_version"
  --build-number "$build_number"
  --probe-runtime
)
app_architectures="$(/usr/bin/lipo -archs \
  "$app_path/Contents/MacOS/$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist")")"
if [[ " $app_architectures " == *" arm64 "* && \
      " $app_architectures " == *" x86_64 "* ]]; then
  verification_arguments+=(--require-universal)
fi
if (( notarize == 1 )); then
  verification_arguments+=(--require-notarized)
fi
"$repo_root/scripts/verify-dmg.sh" "${verification_arguments[@]}"

if [[ -e "$dmg_path" ]]; then
  [[ ! -e "$backup_path" ]] || die "backup path unexpectedly exists: $backup_path"
  /bin/mv -- "$dmg_path" "$backup_path"
fi
if ! /bin/mv -- "$staged_dmg" "$dmg_path"; then
  if [[ -e "$backup_path" && ! -e "$dmg_path" ]]; then
    /bin/mv -- "$backup_path" "$dmg_path"
  fi
  die "could not move the verified disk image into place"
fi
if [[ -e "$backup_path" ]]; then
  /bin/rm -f -- "$backup_path"
fi

print -- "Created: $dmg_path"
print -- "Volume name: $volume_name"
if (( notarize == 1 )); then
  print -- "Distribution: Developer ID signed and notarized"
elif [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  print -- "Distribution: Developer ID signed (not notarized)"
else
  print -- "Distribution: unsigned DMG with ad-hoc-signed app"
fi
