#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
preview_app="$repo_root/dist-preview/Onyx Preview.app"
preview_executable="$preview_app/Contents/MacOS/Onyx"
prepared_app="$repo_root/dist-preview/.Onyx Preview.prepared.$$.app"
preview_bundle_identifier="app.onyx.preview"
preview_display_name="Onyx Preview"
preview_build_number="$(/bin/date -u +%Y%m%d%H%M%S)"
preview_source_revision="$(/usr/bin/git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || {
  print -u2 -- "package-preview: could not resolve the repository HEAD for provenance"
  exit 1
}
[[ "$preview_source_revision" =~ '^[0-9a-f]{40}$' ]] || {
  print -u2 -- "package-preview: repository HEAD is not a full commit SHA: $preview_source_revision"
  exit 1
}

# The bundle records a commit SHA as an exact source-provenance claim. A dirty
# checkout would compile files that are not represented by that SHA, and the
# resulting preview would look trustworthy while actually being unreproducible.
# Pete's unrelated document/artifact files may remain untracked in this
# checkout, so only build-input paths are considered here. Check both ends of
# packaging to catch edits made while Swift is compiling.
assert_source_clean() {
  local current_revision tracked_changes untracked_inputs
  current_revision="$(/usr/bin/git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || \
    die "could not re-read repository HEAD while checking preview provenance"
  [[ "$current_revision" == "$preview_source_revision" ]] || \
    die "repository HEAD changed while packaging; refusing to stamp stale provenance"
  if /usr/bin/git -C "$repo_root" diff-index --quiet HEAD -- \
      Package.swift Package.resolved Sources support scripts >/dev/null 2>&1; then
    tracked_changes=0
  else
    tracked_changes=$?
  fi
  if (( tracked_changes != 0 )); then
    die "tracked build inputs changed; commit or stash them before packaging a revisioned preview"
  fi
  untracked_inputs="$(/usr/bin/git -C "$repo_root" ls-files --others --exclude-standard -- \
    Package.swift Package.resolved Sources support scripts 2>/dev/null)"
  [[ -z "$untracked_inputs" ]] ||
    die "untracked build inputs would make the embedded revision inaccurate: ${(j:, :)${(f)untracked_inputs}}"
}
# Keep the local preview tied to the certificate that already owns its macOS
# privacy grants. An explicit environment override remains available for a
# different machine or a rotated development certificate; silently choosing
# whichever identity happens to sort first can make every rebuild look like a
# new client to macOS.
stable_signing_identity="71E83D4C74C2320E54ABA79ABA79B2D75B8A1B8A"
signing_identity="${ONYX_PREVIEW_CODESIGN_IDENTITY:-$stable_signing_identity}"
signing_requirement="${ONYX_PREVIEW_CODESIGN_REQUIREMENT:-}"
stop_running=0

usage() {
  cat <<'EOF'
Build and atomically replace the one stable Onyx preview application.

Usage:
  scripts/package-preview.sh [--stop-running]

Options:
  --stop-running   Build and verify the replacement first, then gracefully stop
                   only the process executing dist-preview/Onyx Preview.app.
                   Never searches for or kills app-server processes globally.
  -h, --help       Show this help.

Environment:
  ONYX_PREVIEW_CODESIGN_IDENTITY
      Persistent Code Signing identity (prefer its SHA-1 fingerprint). When
      omitted, Onyx uses the certificate that owns this preview's existing
      macOS privacy grants. Set this when moving the preview to another
      machine or rotating that certificate. Set it to `-` only when an
      explicitly ad-hoc preview is required. If no valid identity is found,
      packaging fails instead of silently using ad hoc.
  ONYX_PREVIEW_CODESIGN_REQUIREMENT
      Optional certificate-pinned requirement body after `designated =>`. Use
      only with ONYX_PREVIEW_CODESIGN_IDENTITY.

This script has a fixed path, display name, and bundle ID. It never launches
Onyx. A certificate-backed signature keeps macOS privacy permissions associated
with the same client across rebuilds; ad-hoc signing cannot provide that.
EOF
}

die() {
  print -u2 -- "package-preview: $*"
  exit 1
}

cleanup() {
  if [[ -d "$prepared_app" ]]; then
    /bin/rm -rf -- "$prepared_app"
  fi
}
trap cleanup EXIT

lsof_pids_or_die() {
  [[ -x /usr/sbin/lsof ]] || die "cannot inspect the preview because /usr/sbin/lsof is unavailable"
  local temp_dir
  temp_dir="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/onyx-package-preview-lsof.XXXXXX")" || \
    die "could not create a private directory for preview inspection"
  local output_file="$temp_dir/output"
  local error_file="$temp_dir/error"
  local lsof_exit=0

  /usr/sbin/lsof "$@" >| "$output_file" 2>| "$error_file" || lsof_exit=$?
  # Status 1 with no diagnostic is lsof's ordinary no-match result. Everything
  # else, including a partial-output failure, must fail closed so packaging
  # never signals or replaces an app after an incomplete inspection.
  if [[ -s "$error_file" ]] || (( lsof_exit > 1 )) || \
     (( lsof_exit == 1 && $(/usr/bin/wc -c < "$output_file") > 0 )); then
    local diagnostic="$(<"$error_file")"
    [[ -n "$diagnostic" ]] || diagnostic="lsof exited with status $lsof_exit"
    /bin/rm -rf -- "$temp_dir"
    die "could not inspect the preview process: $diagnostic"
  fi
  [[ -f "$output_file" ]] && local output="$(<"$output_file")" || local output=""
  /bin/rm -rf -- "$temp_dir"
  print -r -- "$output"
}

while (( $# > 0 )); do
  case "$1" in
    --stop-running)
      stop_running=1
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

if [[ -z "$signing_identity" ]]; then
  die "the preview signing identity is empty; set"\
      "ONYX_PREVIEW_CODESIGN_IDENTITY to a certificate fingerprint, or set"\
      "it to '-' to explicitly request ad-hoc signing"
fi

[[ ! -L "$preview_app" && ! -L "$preview_executable" ]] || \
  die "refusing to operate through a symbolic link: $preview_app"

assert_source_clean

pid_owns_preview_executable() {
  local preview_pid="$1"
  [[ "$(lsof_pids_or_die -a -p "$preview_pid" -d txt -t -- \
    "$preview_executable")" == "$preview_pid" ]]
}

package_arguments=(
  debug
  "$prepared_app"
  --display-name "$preview_display_name"
  --bundle-id "$preview_bundle_identifier"
  --build-number "$preview_build_number"
  --source-revision "$preview_source_revision"
)
if [[ -n "$signing_identity" ]]; then
  package_arguments+=(--signing-identity "$signing_identity" --no-signing-timestamp)
fi
if [[ -n "$signing_requirement" ]]; then
  [[ -n "$signing_identity" ]] || \
    die "ONYX_PREVIEW_CODESIGN_REQUIREMENT requires ONYX_PREVIEW_CODESIGN_IDENTITY"
  package_arguments+=(--designated-requirement "$signing_requirement")
fi

"$repo_root/scripts/package-app.sh" "${package_arguments[@]}"

[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - \
  "$prepared_app/Contents/Info.plist")" == "$preview_display_name" ]] || \
  die "packaged preview display name changed"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
  "$prepared_app/Contents/Info.plist")" == "$preview_bundle_identifier" ]] || \
  die "packaged preview bundle identifier changed"
bundle_source_revision="$(/usr/bin/plutil -extract OnyxSourceRevision raw -o - \
  "$prepared_app/Contents/Info.plist" 2>/dev/null)" || \
  die "packaged preview source revision is missing"
[[ "$bundle_source_revision" == "$preview_source_revision" ]] || \
  die "packaged preview source revision changed"
assert_source_clean

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  code_signature_details="$(/usr/bin/codesign -dvv "$prepared_app" 2>&1)"
  [[ "$code_signature_details" != *'Signature=adhoc'* ]] || \
    die "packaged preview unexpectedly has an ad-hoc signature"
fi

# Only after the complete replacement has built, signed, and verified do we
# inspect or stop the current app. A compiler or signing failure therefore
# leaves the working preview untouched.
preview_pids=()
if [[ -f "$preview_executable" ]]; then
  preview_pids=(${(f)"$(lsof_pids_or_die -a -d txt -t -- "$preview_executable")"})
fi
if (( ${#preview_pids[@]} > 0 && stop_running == 0 )); then
  die "the stable preview is running (PID ${${(j:, :)preview_pids}}); quit it or pass --stop-running"
fi
if (( stop_running == 1 )); then
  remaining=()
  for preview_pid in "${preview_pids[@]}"; do
    [[ "$preview_pid" == <1-> ]] || die "unexpected preview PID: $preview_pid"
    # Revalidate the exact executable immediately before signalling. If the
    # process exited and macOS reused its PID, never signal the replacement.
    pid_owns_preview_executable "$preview_pid" || continue
    if ! /bin/kill -TERM "$preview_pid" 2>/dev/null && \
       pid_owns_preview_executable "$preview_pid"; then
      die "could not stop the owned preview (PID $preview_pid)"
    fi
  done

  for attempt in {1..50}; do
    remaining=()
    for preview_pid in "${preview_pids[@]}"; do
      if pid_owns_preview_executable "$preview_pid"; then
        remaining+=("$preview_pid")
      fi
    done
    (( ${#remaining[@]} == 0 )) && break
    /bin/sleep 0.1
  done

  (( ${#remaining[@]} == 0 )) || \
    die "the owned preview did not stop; refusing to force-kill or replace it"
fi

# Close the restart race before replacing the stable bundle. If something
# relaunched the old executable after the graceful stop, leave both the current
# app and the verified prepared bundle untouched until cleanup.
if [[ -f "$preview_executable" ]]; then
  restarted_pids="$(lsof_pids_or_die -a -d txt -t -- "$preview_executable")"
  [[ -z "$restarted_pids" ]] || \
    die "the stable preview restarted during packaging; refusing to replace it"
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$repo_root/.build/swiftpm-module-cache}"
if [[ -e "$preview_app" ]]; then
  /usr/bin/swift "$repo_root/scripts/atomic-swap.swift" "$preview_app" "$prepared_app" || \
    die "could not atomically replace the stable preview"
else
  /bin/mv -- "$prepared_app" "$preview_app" || \
    die "could not move the verified preview into place"
fi

print -- "Stable preview ready: $preview_app"
