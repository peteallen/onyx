#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "$repo_root/scripts/codex-runtime-common.sh"

cache_dir="${ONYX_CODEX_RUNTIME_CACHE_DIR:-$codex_runtime_default_cache}"
architectures=(arm64 x86_64)

usage() {
  cat <<'EOF'
Fetch and verify Onyx's exact pinned official Codex app-server packages.

Usage:
  scripts/fetch-codex-runtime.sh [--cache-dir PATH] [--architectures MODE]

Options:
  --cache-dir PATH       Local archive cache. Defaults to .artifacts/codex-runtime.
  --architectures MODE   native, universal, arm64, or x86_64.
  -h, --help             Show this help.

This helper downloads only the URLs and exact version recorded in
support/codex-runtime-manifest.json. It verifies byte size and SHA-256 before
moving an archive into the cache. Packaging never downloads anything; it only
consumes these explicit local artifacts.
EOF
}

require_value() {
  (( $# >= 2 )) || codex_runtime_die "$1 requires a value"
  [[ -n "$2" ]] || codex_runtime_die "$1 requires a non-empty value"
}

while (( $# > 0 )); do
  case "$1" in
    --cache-dir)
      require_value "$1" "${2:-}"
      cache_dir="$2"
      shift 2
      ;;
    --architectures)
      require_value "$1" "${2:-}"
      case "$2" in
        native)
          architectures=("$(/usr/bin/uname -m)")
          ;;
        universal)
          architectures=(arm64 x86_64)
          ;;
        arm64|x86_64)
          architectures=("$2")
          ;;
        *)
          codex_runtime_die "architectures must be native, universal, arm64, or x86_64"
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      codex_runtime_die "unknown option: $1"
      ;;
  esac
done

codex_runtime_require_manifest
[[ "$cache_dir" == /* ]] || cache_dir="$PWD/$cache_dir"
cache_dir="${cache_dir:A}"
/bin/mkdir -p "$cache_dir"
[[ -d "$cache_dir" && ! -L "$cache_dir" ]] ||
  codex_runtime_die "runtime cache must be a real directory: $cache_dir"

fetch_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/onyx-codex-runtime-fetch.XXXXXX")"
cleanup() {
  local exit_code=$?
  /bin/rm -rf -- "$fetch_root"
  return $exit_code
}
trap cleanup EXIT

download_architectures=()
for architecture in "${architectures[@]}"; do
  index="$(codex_runtime_artifact_index_for_architecture "$architecture")"
  file_name="$(codex_runtime_manifest_value "artifacts.$index.fileName")"
  expected_sha="$(codex_runtime_manifest_value "artifacts.$index.sha256")"
  expected_size="$(codex_runtime_manifest_value "artifacts.$index.size")"
  destination="$cache_dir/$file_name"
  if [[ -e "$destination" && ! -f "$destination" ]]; then
    codex_runtime_die "refusing to replace a non-regular cached archive: $destination"
  fi
  if [[ -f "$destination" && ! -L "$destination" && \
        "$(/usr/bin/stat -f %z "$destination")" == "$expected_size" && \
        "$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')" == "$expected_sha" ]]; then
    print -- "Pinned archive already verified: $destination"
  else
    download_architectures+=("$architecture")
  fi
done

if (( ${#download_architectures[@]} == 0 )); then
  exit 0
fi

checksum_file_name="$(codex_runtime_manifest_value checksumManifest.fileName)"
checksum_staging="$fetch_root/$checksum_file_name"
print -- "Fetching pinned Codex checksum manifest…"
/usr/bin/curl --fail --location --silent --show-error \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 900 --retry 3 --retry-delay 2 --retry-all-errors \
  "$(codex_runtime_manifest_value checksumManifest.url)" \
  --output "$checksum_staging"
[[ "$(/usr/bin/shasum -a 256 "$checksum_staging" | /usr/bin/awk '{print $1}')" == \
   "$(codex_runtime_manifest_value checksumManifest.sha256)" ]] ||
  codex_runtime_die "official checksum manifest SHA-256 mismatch"

for architecture in "${download_architectures[@]}"; do
  index="$(codex_runtime_artifact_index_for_architecture "$architecture")"
  file_name="$(codex_runtime_manifest_value "artifacts.$index.fileName")"
  expected_sha="$(codex_runtime_manifest_value "artifacts.$index.sha256")"
  expected_size="$(codex_runtime_manifest_value "artifacts.$index.size")"
  expected_manifest_line="$expected_sha  $file_name"
  /usr/bin/grep -Fx -- "$expected_manifest_line" "$checksum_staging" >/dev/null ||
    codex_runtime_die "official checksum manifest does not match $file_name"

  destination="$cache_dir/$file_name"
  [[ ! -L "$destination" ]] ||
    codex_runtime_die "refusing to replace a symbolic link: $destination"

  staging="$fetch_root/$file_name"
  print -- "Fetching pinned Codex $architecture package…"
  /usr/bin/curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 900 --retry 3 --retry-delay 2 --retry-all-errors \
    "$(codex_runtime_manifest_value "artifacts.$index.url")" \
    --output "$staging"
  [[ "$(/usr/bin/stat -f %z "$staging")" == "$expected_size" ]] ||
    codex_runtime_die "$file_name size mismatch"
  [[ "$(/usr/bin/shasum -a 256 "$staging" | /usr/bin/awk '{print $1}')" == "$expected_sha" ]] ||
    codex_runtime_die "$file_name SHA-256 mismatch"

  validation_root="$fetch_root/validation-$architecture"
  /bin/mkdir -p "$validation_root"
  codex_runtime_validate_archive "$architecture" "$staging" "$validation_root" >/dev/null
  /bin/mv -f -- "$staging" "$destination"
  print -- "Pinned archive ready: $destination"
done
