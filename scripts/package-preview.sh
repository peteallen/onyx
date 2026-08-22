#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
preview_app="$repo_root/dist-preview/Onyx Preview.app"
preview_executable="$preview_app/Contents/MacOS/Onyx"
preview_bundle_identifier="app.onyx.preview"
preview_display_name="Onyx Preview"
preview_build_number="$(/bin/date -u +%Y%m%d%H%M%S)"
signing_identity="${ONYX_PREVIEW_CODESIGN_IDENTITY:-}"
signing_requirement="${ONYX_PREVIEW_CODESIGN_REQUIREMENT:-}"
stop_running=0

usage() {
  cat <<'EOF'
Build and atomically replace the one stable Onyx preview application.

Usage:
  scripts/package-preview.sh [--stop-running]

Options:
  --stop-running   Gracefully stop only the process executing the existing
                   dist-preview/Onyx Preview.app, then package its replacement.
                   Never searches for or kills app-server processes globally.
  -h, --help       Show this help.

Environment:
  ONYX_PREVIEW_CODESIGN_IDENTITY
      Persistent Code Signing identity (prefer its SHA-1 fingerprint). When
      omitted, the first valid identity in the default user Keychain is used.
      Set this to `-` only when an explicitly ad-hoc preview is required. If no
      valid identity is found, packaging fails instead of silently using ad hoc.
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
  login_keychain="$(/usr/bin/security default-keychain -d user 2>/dev/null \
    | /usr/bin/tr -d '"[:space:]' || true)"
  if [[ -n "$login_keychain" && -f "$login_keychain" ]]; then
    identity_output="$(/usr/bin/security find-identity -v -p codesigning \
      "$login_keychain" 2>/dev/null || true)"
    for identity_line in "${(f)identity_output}"; do
      if [[ "$identity_line" =~ '([0-9A-Fa-f]{40})[[:space:]]+"' ]]; then
        signing_identity="${match[1]}"
        break
      fi
    done
  fi
fi

if [[ -z "$signing_identity" ]]; then
  die "no valid code-signing identity found in the default user Keychain;"\
      "set ONYX_PREVIEW_CODESIGN_IDENTITY to a certificate fingerprint, or"\
      "set it to '-' to explicitly request ad-hoc signing"
fi

[[ ! -L "$preview_app" && ! -L "$preview_executable" ]] || \
  die "refusing to operate through a symbolic link: $preview_app"

preview_pids=()
if [[ -f "$preview_executable" ]]; then
  preview_pids=(${(f)"$(/usr/sbin/lsof -a -d txt -t -- "$preview_executable" 2>/dev/null || true)"})
fi

pid_owns_preview_executable() {
  local preview_pid="$1"
  [[ "$(/usr/sbin/lsof -a -p "$preview_pid" -d txt -t -- \
    "$preview_executable" 2>/dev/null || true)" == "$preview_pid" ]]
}

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

package_arguments=(
  debug
  "$preview_app"
  --display-name "$preview_display_name"
  --bundle-id "$preview_bundle_identifier"
  --build-number "$preview_build_number"
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
  "$preview_app/Contents/Info.plist")" == "$preview_display_name" ]] || \
  die "packaged preview display name changed"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
  "$preview_app/Contents/Info.plist")" == "$preview_bundle_identifier" ]] || \
  die "packaged preview bundle identifier changed"

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  code_signature_details="$(/usr/bin/codesign -dvv "$preview_app" 2>&1)"
  [[ "$code_signature_details" != *'Signature=adhoc'* ]] || \
    die "packaged preview unexpectedly has an ad-hoc signature"
fi

print -- "Stable preview ready: $preview_app"
