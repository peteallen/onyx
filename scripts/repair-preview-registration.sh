#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
stable_app="$repo_root/dist-preview/Onyx Preview.app"
run_gc=0

usage() {
  cat <<'EOF'
Repair LaunchServices entries left by old local Onyx previews.

Usage:
  scripts/repair-preview-registration.sh [--gc]

The default operation only unregisters existing app bundles below this checkout
whose IDs are legacy Onyx IDs (`dev.peteallen.onyx.*`, `com.peteallen.onyx`, or
`com.peteallen.onyx.preview`, or timestamped `app.onyx.preview.b<timestamp>`), then force-registers the stable
`dist-preview/Onyx Preview.app`. It never unregisters that canonical path,
deletes an app bundle, or deletes the LaunchServices database. `--gc`
additionally asks LaunchServices to garbage-collect other stale records (a
broader user-level database operation).
EOF
}

die() {
  print -u2 -- "repair-preview-registration: $*"
  exit 1
}

is_launchservices_unavailable() {
  local diagnostic="$1"
  [[ "$diagnostic" == *"-10822"* ||
     "$diagnostic" == *"kLSServerCommunicationErr"* ]]
}

while (( $# > 0 )); do
  case "$1" in
    --gc)
      run_gc=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -x "$lsregister" ]] || die "lsregister is unavailable at $lsregister"

stable_exists=0
if [[ -e "$stable_app" ]]; then
  [[ -d "$stable_app" && ! -L "$stable_app" ]] || \
    die "canonical preview is not a regular app bundle: $stable_app"
  stable_bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
    "$stable_app/Contents/Info.plist" 2>/dev/null || true)"
  stable_display_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - \
    "$stable_app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$stable_bundle_identifier" == "app.onyx.preview" ]] || \
    die "canonical preview bundle identifier is not app.onyx.preview: $stable_app"
  [[ "$stable_display_name" == "Onyx Preview" ]] || \
    die "canonical preview display name is not Onyx Preview: $stable_app"
  stable_exists=1
fi

old_apps=()
for candidate in "$repo_root"/dist*/**/*.app(N); do
  [[ -d "$candidate" && ! -L "$candidate" ]] || continue
  [[ "$candidate" == "$stable_app" ]] && continue
  bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
    "$candidate/Contents/Info.plist" 2>/dev/null || true)"
  case "$bundle_identifier" in
    app.onyx.preview.b*|dev.peteallen.onyx.*|com.peteallen.onyx|com.peteallen.onyx.preview)
      old_apps+=("$candidate")
      ;;
  esac
done

registration_unavailable=0
for old_app in "${old_apps[@]}"; do
  print -- "Unregistering legacy Onyx app: $old_app"
  unregister_output=""
  if ! unregister_output="$("$lsregister" -u "$old_app" 2>&1)"; then
    # LaunchServices returns kLSApplicationNotFoundErr (-10814) when a legacy
    # bundle still exists on disk but is already absent from its database.
    # That is the desired end state, so keep repairing the remaining records.
    if [[ "$unregister_output" == *"-10814"* ]]; then
      print -- "Legacy app was already unregistered: $old_app"
    elif is_launchservices_unavailable "$unregister_output"; then
      # Registration and unregistration share the same LaunchServices server.
      # If it is unavailable, do not fail before the canonical direct-launch
      # fallback gets a chance to start the already-verified bundle. Leaving
      # stale records in place is recoverable; treating a malformed bundle as
      # recoverable would hide a real packaging error, so every other error
      # remains fatal.
      print -u2 -- "LaunchServices is unavailable; skipping legacy registration cleanup"
      registration_unavailable=1
      break
    else
      print -u2 -- "$unregister_output"
      die "could not unregister legacy Onyx app: $old_app"
    fi
  fi
done

if (( stable_exists == 1 )); then
  # LaunchServices is not available in some headless/macOS automation
  # sessions (lsregister reports kLSServerCommunicationErr/-10822). That is
  # a registration problem, not a malformed bundle; run-preview has a
  # canonical direct-launch fallback for this narrow condition. Keep failing
  # closed for every other registration error so a real bundle problem is not
  # hidden.
  register_output=""
  if (( registration_unavailable == 1 )); then
    print -u2 -- "LaunchServices is unavailable; the canonical preview will be launched directly: $stable_app"
  elif register_output="$("$lsregister" -f "$stable_app" 2>&1)"; then
    [[ -z "$register_output" ]] || print -- "$register_output"
    print -- "Registered stable preview: $stable_app"
  elif is_launchservices_unavailable "$register_output"; then
    print -u2 -- "LaunchServices is unavailable; the canonical preview will be launched directly: $stable_app"
  else
    print -u2 -- "$register_output"
    die "could not register the stable preview: $stable_app"
  fi
else
  print -- "Stable preview is not packaged yet: $stable_app"
fi

if (( run_gc == 1 && registration_unavailable == 0 )); then
  gc_output=""
  if gc_output="$("$lsregister" -gc 2>&1)"; then
    [[ -z "$gc_output" ]] || print -- "$gc_output"
    print -- "LaunchServices stale-record garbage collection requested"
  elif is_launchservices_unavailable "$gc_output"; then
    print -u2 -- "LaunchServices is unavailable; skipped stale-record garbage collection"
  else
    print -u2 -- "$gc_output"
    die "could not garbage-collect stale LaunchServices records"
  fi
elif (( run_gc == 1 )); then
  print -u2 -- "LaunchServices is unavailable; skipped stale-record garbage collection"
fi
