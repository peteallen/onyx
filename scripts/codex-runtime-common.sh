#!/bin/zsh

# Shared, source-only contract for the pinned standalone Codex runtime. Keep
# this file free of side effects so packaging, fetch, and verification can use
# the same fail-closed checks.

codex_runtime_repo_root="${0:A:h:h}"
codex_runtime_manifest="$codex_runtime_repo_root/support/codex-runtime-manifest.json"
codex_runtime_default_cache="$codex_runtime_repo_root/.artifacts/codex-runtime"

codex_runtime_die() {
  print -u2 -- "codex-runtime: $*"
  exit 1
}

codex_runtime_manifest_value() {
  local key_path="$1"
  /usr/bin/plutil -extract "$key_path" raw -o - "$codex_runtime_manifest" 2>/dev/null ||
    codex_runtime_die "invalid or missing manifest value: $key_path"
}

codex_runtime_require_manifest() {
  [[ -f "$codex_runtime_manifest" && ! -L "$codex_runtime_manifest" ]] ||
    codex_runtime_die "missing pinned runtime manifest: $codex_runtime_manifest"
  codex_runtime_manifest_value layoutVersion >/dev/null

  [[ "$(codex_runtime_manifest_value layoutVersion)" == "1" ]] ||
    codex_runtime_die "unsupported pinned runtime manifest layout"
  [[ "$(codex_runtime_manifest_value version)" == "0.149.0" ]] ||
    codex_runtime_die "unexpected pinned runtime version"
  [[ "$(codex_runtime_manifest_value tag)" == "rust-v0.149.0" ]] ||
    codex_runtime_die "unexpected pinned runtime tag"
  [[ "$(codex_runtime_manifest_value variant)" == "codex-app-server" ]] ||
    codex_runtime_die "unexpected pinned runtime variant"
  [[ "$(codex_runtime_manifest_value entrypoint)" == "bin/codex-app-server" ]] ||
    codex_runtime_die "unexpected pinned runtime entrypoint"

  local executable_count="$(codex_runtime_manifest_value executables)"
  local identifier_count="$(codex_runtime_manifest_value codeIdentifiers)"
  [[ "$identifier_count" == "$executable_count" ]] ||
    codex_runtime_die "pinned runtime code-identifier count does not match its executables"
  local executable_index=""
  local code_identifier=""
  for (( executable_index=0; executable_index<executable_count; executable_index++ )); do
    code_identifier="$(codex_runtime_manifest_value "codeIdentifiers.$executable_index")"
    [[ "$code_identifier" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]] ||
      codex_runtime_die "invalid pinned runtime code identifier at index $executable_index"
  done

  local license_path="$codex_runtime_repo_root/$(codex_runtime_manifest_value license.path)"
  local notice_path="$codex_runtime_repo_root/$(codex_runtime_manifest_value notice.path)"
  for attribution_path in "$license_path" "$notice_path"; do
    [[ -f "$attribution_path" && ! -L "$attribution_path" ]] ||
      codex_runtime_die "missing pinned runtime attribution: $attribution_path"
  done
  [[ "$(/usr/bin/shasum -a 256 "$license_path" | /usr/bin/awk '{print $1}')" == \
     "$(codex_runtime_manifest_value license.sha256)" ]] ||
    codex_runtime_die "pinned runtime LICENSE checksum mismatch"
  [[ "$(/usr/bin/shasum -a 256 "$notice_path" | /usr/bin/awk '{print $1}')" == \
     "$(codex_runtime_manifest_value notice.sha256)" ]] ||
    codex_runtime_die "pinned runtime NOTICE checksum mismatch"
}

codex_runtime_artifact_index_for_architecture() {
  case "$1" in
    arm64) print -- 0 ;;
    x86_64) print -- 1 ;;
    *) codex_runtime_die "unsupported Codex runtime architecture: $1" ;;
  esac
}

codex_runtime_target_for_architecture() {
  local index="$(codex_runtime_artifact_index_for_architecture "$1")"
  codex_runtime_manifest_value "artifacts.$index.target"
}

codex_runtime_archive_for_architecture() {
  local architecture="$1"
  local index="$(codex_runtime_artifact_index_for_architecture "$architecture")"
  local override=""
  case "$architecture" in
    arm64) override="${ONYX_CODEX_RUNTIME_ARCHIVE_ARM64:-}" ;;
    x86_64) override="${ONYX_CODEX_RUNTIME_ARCHIVE_X86_64:-}" ;;
  esac
  if [[ -n "$override" ]]; then
    [[ "$override" == /* ]] || override="$PWD/$override"
    print -- "${override:A}"
  else
    local cache_dir="${ONYX_CODEX_RUNTIME_CACHE_DIR:-$codex_runtime_default_cache}"
    [[ "$cache_dir" == /* ]] || cache_dir="$PWD/$cache_dir"
    print -- "${cache_dir:A}/$(codex_runtime_manifest_value "artifacts.$index.fileName")"
  fi
}

codex_runtime_validate_archive() {
  local architecture="$1"
  local archive_path="$2"
  local destination_root="$3"
  local index="$(codex_runtime_artifact_index_for_architecture "$architecture")"
  local target="$(codex_runtime_manifest_value "artifacts.$index.target")"
  local expected_archive_name="$(codex_runtime_manifest_value "artifacts.$index.fileName")"
  local expected_sha="$(codex_runtime_manifest_value "artifacts.$index.sha256")"
  local expected_size="$(codex_runtime_manifest_value "artifacts.$index.size")"
  local actual_sha=""
  local actual_size=""

  [[ -f "$archive_path" && ! -L "$archive_path" ]] ||
    codex_runtime_die "missing $architecture runtime archive: $archive_path"
  actual_size="$(/usr/bin/stat -f %z "$archive_path" 2>/dev/null || true)"
  [[ "$actual_size" == "$expected_size" ]] ||
    codex_runtime_die "$expected_archive_name size mismatch: expected $expected_size, found ${actual_size:-unknown}"
  actual_sha="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    codex_runtime_die "$expected_archive_name SHA-256 mismatch"

  local archive_entries_file="$destination_root/$target.entries"
  /usr/bin/tar -tzf "$archive_path" >| "$archive_entries_file" ||
    codex_runtime_die "could not list $expected_archive_name"
  local expected_entries_file="$destination_root/$target.expected-entries"
  : >| "$expected_entries_file"
  local expected_entry_count="$(codex_runtime_manifest_value expectedEntries)"
  local expected_entry=""
  for (( entry_index=0; entry_index<expected_entry_count; entry_index++ )); do
    expected_entry="$(codex_runtime_manifest_value "expectedEntries.$entry_index")"
    print -r -- "$expected_entry" >> "$expected_entries_file"
  done
  /usr/bin/cmp -s "$expected_entries_file" "$archive_entries_file" ||
    codex_runtime_die "$expected_archive_name contains unexpected, missing, or reordered entries"
  if /usr/bin/awk '/^(\/|\.\.\/)|\/\.\.($|\/)/ { found=1 } END { exit !found }' \
    "$archive_entries_file"; then
    codex_runtime_die "$expected_archive_name contains an unsafe path"
  fi

  local archive_types_file="$destination_root/$target.types"
  /usr/bin/tar -cf - --format=mtree --options='mtree:!all,type,link' \
    "@$archive_path" 2>/dev/null >| "$archive_types_file" ||
    codex_runtime_die "could not inspect entry types in $expected_archive_name"
  if /usr/bin/awk '$0 !~ /^#mtree$/ && $0 !~ / type=(file|dir)$/ { found=1 } END { exit !found }' \
    "$archive_types_file"; then
    codex_runtime_die "$expected_archive_name contains a symlink, hard link, or unsupported entry"
  fi

  local extracted_root="$destination_root/$target"
  /bin/mkdir -p "$extracted_root"
  /usr/bin/tar -xzf "$archive_path" -C "$extracted_root" ||
    codex_runtime_die "could not extract $expected_archive_name"

  local metadata="$extracted_root/codex-package.json"
  [[ -f "$metadata" && ! -L "$metadata" ]] ||
    codex_runtime_die "$expected_archive_name is missing codex-package.json"
  /usr/bin/plutil -extract layoutVersion raw -o - "$metadata" >/dev/null 2>&1 ||
    codex_runtime_die "$expected_archive_name has invalid codex-package.json"
  [[ "$(/usr/bin/plutil -extract layoutVersion raw -o - "$metadata")" == \
     "$(codex_runtime_manifest_value layoutVersion)" ]] ||
    codex_runtime_die "$expected_archive_name has the wrong layout version"
  for key in version variant entrypoint resourcesDir pathDir; do
    [[ "$(/usr/bin/plutil -extract "$key" raw -o - "$metadata")" == \
       "$(codex_runtime_manifest_value "$key")" ]] ||
      codex_runtime_die "$expected_archive_name has the wrong $key"
  done
  [[ "$(/usr/bin/plutil -extract target raw -o - "$metadata")" == "$target" ]] ||
    codex_runtime_die "$expected_archive_name has the wrong target"

  local executable_count="$(codex_runtime_manifest_value executables)"
  local executable_relative=""
  local executable_path=""
  local executable_architectures=""
  for (( executable_index=0; executable_index<executable_count; executable_index++ )); do
    executable_relative="$(codex_runtime_manifest_value "executables.$executable_index")"
    executable_path="$extracted_root/$executable_relative"
    [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] ||
      codex_runtime_die "$expected_archive_name has a missing or non-executable $executable_relative"
    executable_architectures="$(/usr/bin/lipo -archs "$executable_path" 2>/dev/null || true)"
    [[ "$executable_architectures" == "$architecture" ]] ||
      codex_runtime_die "$expected_archive_name has wrong architecture for $executable_relative: ${executable_architectures:-unknown}"
  done

  print -- "$extracted_root"
}

codex_runtime_copy_attribution() {
  local runtime_root="$1"
  /usr/bin/install -m 644 \
    "$codex_runtime_repo_root/$(codex_runtime_manifest_value license.path)" \
    "$runtime_root/LICENSE"
  /usr/bin/install -m 644 \
    "$codex_runtime_repo_root/$(codex_runtime_manifest_value notice.path)" \
    "$runtime_root/NOTICE"
}

codex_runtime_write_expected_paths() {
  local destination="$1"
  local expected_entry_count="$(codex_runtime_manifest_value expectedEntries)"
  local expected_entry=""
  : >| "$destination"
  for (( entry_index=0; entry_index<expected_entry_count; entry_index++ )); do
    expected_entry="$(codex_runtime_manifest_value "expectedEntries.$entry_index")"
    [[ "$expected_entry" == */ ]] && expected_entry="${expected_entry%/}"
    print -r -- "$expected_entry" >> "$destination"
  done
  print -- LICENSE >> "$destination"
  print -- NOTICE >> "$destination"
  /usr/bin/sort -o "$destination" "$destination"
}

codex_runtime_verify_installed_tree() {
  local runtime_package="$1"
  local inspection_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/onyx-codex-tree.XXXXXX")" ||
    codex_runtime_die "could not prepare installed runtime tree inspection"
  local expected_paths="$inspection_root/expected"
  local actual_paths="$inspection_root/actual"
  codex_runtime_write_expected_paths "$expected_paths"
  (
    cd "$runtime_package" || exit 1
    /usr/bin/find . -mindepth 1 -print | /usr/bin/sed 's#^\./##' | /usr/bin/sort
  ) >| "$actual_paths" || {
    /bin/rm -rf -- "$inspection_root"
    codex_runtime_die "could not inspect installed runtime tree: $runtime_package"
  }
  if ! /usr/bin/cmp -s "$expected_paths" "$actual_paths"; then
    /bin/rm -rf -- "$inspection_root"
    codex_runtime_die "installed runtime contains unexpected or missing paths: $runtime_package"
  fi
  /bin/rm -rf -- "$inspection_root"
}

codex_runtime_verify_installed_package() {
  local runtime_package="$1"
  local architecture="$2"
  local target="$(codex_runtime_target_for_architecture "$architecture")"
  [[ "${runtime_package:t}" == "$target" ]] ||
    codex_runtime_die "runtime package path does not match target $target: $runtime_package"
  [[ -d "$runtime_package" && ! -L "$runtime_package" ]] ||
    codex_runtime_die "missing installed runtime package: $runtime_package"
  codex_runtime_verify_installed_tree "$runtime_package"
  local metadata="$runtime_package/codex-package.json"
  [[ -f "$metadata" && ! -L "$metadata" ]] ||
    codex_runtime_die "installed runtime is missing codex-package.json: $runtime_package"
  for metadata_key in layoutVersion version variant entrypoint resourcesDir pathDir; do
    [[ "$(/usr/bin/plutil -extract "$metadata_key" raw -o - "$metadata" 2>/dev/null)" == \
       "$(codex_runtime_manifest_value "$metadata_key")" ]] ||
      codex_runtime_die "installed runtime has the wrong $metadata_key: $runtime_package"
  done
  [[ "$(/usr/bin/plutil -extract target raw -o - "$metadata" 2>/dev/null)" == "$target" ]] ||
    codex_runtime_die "installed runtime has the wrong target: $runtime_package"

  local executable_count="$(codex_runtime_manifest_value executables)"
  local executable_relative=""
  local executable_path=""
  local expected_code_identifier=""
  local actual_code_identifier=""
  for (( executable_index=0; executable_index<executable_count; executable_index++ )); do
    executable_relative="$(codex_runtime_manifest_value "executables.$executable_index")"
    executable_path="$runtime_package/$executable_relative"
    expected_code_identifier="$(codex_runtime_manifest_value \
      "codeIdentifiers.$executable_index")"
    [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] ||
      codex_runtime_die "installed runtime executable is missing or invalid: $executable_path"
    [[ "$(/usr/bin/lipo -archs "$executable_path" 2>/dev/null)" == "$architecture" ]] ||
      codex_runtime_die "installed runtime executable has the wrong architecture: $executable_path"
    /usr/bin/codesign --verify --strict --verbose=2 "$executable_path" ||
      codex_runtime_die "installed runtime executable signature is invalid: $executable_path"
    local signature_details="$(/usr/bin/codesign -dvv "$executable_path" 2>&1 || true)"
    actual_code_identifier="$(print -r -- "$signature_details" | \
      /usr/bin/sed -n 's/^Identifier=//p')"
    [[ "$actual_code_identifier" == "$expected_code_identifier" ]] ||
      codex_runtime_die "installed runtime executable has the wrong code identifier: $executable_path"
    [[ "$signature_details" == *"flags="*"runtime"* ]] ||
      codex_runtime_die "installed runtime executable lacks hardened runtime: $executable_path"
    if [[ "$executable_relative" == "bin/codex-app-server" || \
          "$executable_relative" == "bin/codex-code-mode-host" ]]; then
      local actual_entitlements="$(/usr/bin/codesign -d --entitlements :- \
        "$executable_path" 2>/dev/null || true)"
      actual_entitlements="$(print -rn -- "$actual_entitlements" | \
        /usr/bin/plutil -convert xml1 -o - - 2>/dev/null || true)"
      local expected_entitlements="$(/usr/bin/plutil -convert xml1 -o - \
        "$codex_runtime_repo_root/support/codex-runtime-entitlements.plist")"
      [[ -n "$actual_entitlements" && "$actual_entitlements" == "$expected_entitlements" ]] ||
        codex_runtime_die "installed runtime lost required execution entitlements: $executable_path"
    else
      local unexpected_entitlements="$(/usr/bin/codesign -d --entitlements :- \
        "$executable_path" 2>/dev/null || true)"
      [[ -z "$unexpected_entitlements" ]] ||
        codex_runtime_die "installed runtime has unexpected entitlements: $executable_path"
    fi
  done
  for attribution_name in LICENSE NOTICE; do
    [[ -f "$runtime_package/$attribution_name" && ! -L "$runtime_package/$attribution_name" ]] ||
      codex_runtime_die "installed runtime is missing $attribution_name: $runtime_package"
  done
  local expected_attribution_path=""
  local expected_attribution_sha=""
  expected_attribution_path="$runtime_package/LICENSE"
  expected_attribution_sha="$(codex_runtime_manifest_value license.sha256)"
  [[ "$(/usr/bin/shasum -a 256 "$expected_attribution_path" | /usr/bin/awk '{print $1}')" == \
     "$expected_attribution_sha" ]] ||
    codex_runtime_die "installed runtime LICENSE checksum mismatch: $runtime_package"
  expected_attribution_path="$runtime_package/NOTICE"
  expected_attribution_sha="$(codex_runtime_manifest_value notice.sha256)"
  [[ "$(/usr/bin/shasum -a 256 "$expected_attribution_path" | /usr/bin/awk '{print $1}')" == \
     "$expected_attribution_sha" ]] ||
    codex_runtime_die "installed runtime NOTICE checksum mismatch: $runtime_package"
}

# Exercise the installed native app-server from its final package location.
# Static tree/signature checks cannot prove that dyld can load the helper or
# that the process honors the isolated CODEX_HOME at runtime.
codex_runtime_probe_installed_package() (
  set -euo pipefail

  local runtime_package="$1"
  local helper="$runtime_package/$(codex_runtime_manifest_value entrypoint)"
  [[ -f "$helper" && ! -L "$helper" && -x "$helper" ]] ||
    codex_runtime_die "installed runtime app-server is missing or invalid: $helper"

  local probe_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/onyx-codex-probe.XXXXXX")" ||
    codex_runtime_die "could not prepare installed runtime probe"
  probe_root="${probe_root:A}"
  trap '/bin/rm -rf -- "$probe_root"' EXIT

  local codex_home="$probe_root/Application Support/Onyx/Codex"
  local input_pipe="$probe_root/input.pipe"
  local output_file="$probe_root/output.jsonl"
  local error_file="$probe_root/error.log"
  /bin/mkdir -m 700 -p "$codex_home"
  # The helper reports a canonical path (`/private/var/...` on macOS), while
  # TMPDIR and mktemp often spell that same location as `/var/...`. Compare
  # like with like so the probe tests isolation instead of a system alias.
  codex_home="${codex_home:A}"
  /usr/bin/mkfifo -m 600 "$input_pipe"
  # Open both ends in the verifier before the child starts so neither side can
  # block while opening the FIFO. More importantly, keep stdin open until the
  # initialize response has actually arrived; closing a prewritten file at
  # once races app-server shutdown and can occasionally lose that response.
  exec {input_fd}<> "$input_pipe"

  # Restricted macOS runners can deny zsh's harmless background-job priority
  # adjustment. The probe does not depend on that behavior.
  unsetopt BG_NICE
  (
    # Do not let the child inherit the verifier's read/write FIFO descriptor;
    # otherwise it keeps its own stdin alive after the parent closes the pipe.
    exec {input_fd}>&-
    exec /usr/bin/env -i \
      HOME="${HOME:-/var/empty}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="${LANG:-en_US.UTF-8}" \
      CODEX_HOME="$codex_home" \
      "$helper" \
        --listen stdio:// \
        -c 'forced_login_method="chatgpt"' \
        -c 'cli_auth_credentials_store="file"' \
        -c 'mcp_oauth_credentials_store="file"' \
        < "$input_pipe"
  ) > "$output_file" 2> "$error_file" &
  local probe_pid=$!

  print -r -u "$input_fd" -- \
    '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"onyx-release-verifier","title":"Onyx release verifier","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}'

  local initialize_response=""
  local response_line=""
  local response_id=""
  for _ in {1..150}; do
    while IFS= read -r response_line; do
      response_id="$(print -rn -- "$response_line" | \
        /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
      if [[ "$response_id" == "1" ]]; then
        initialize_response="$response_line"
        break
      fi
    done < "$output_file"
    if [[ -n "$initialize_response" ]]; then
      break
    fi
    if ! /bin/kill -0 "$probe_pid" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.1
  done

  [[ -n "$initialize_response" ]] || {
    /bin/kill -TERM "$probe_pid" 2>/dev/null || true
    exec {input_fd}>&-
    wait "$probe_pid" 2>/dev/null || true
    local probe_error="$(<"$error_file")"
    [[ -n "$probe_error" ]] || probe_error="no initialize response"
    codex_runtime_die "installed runtime app-server initialization probe failed: $probe_error"
  }

  print -r -u "$input_fd" -- '{"method":"initialized","params":{}}'
  exec {input_fd}>&-
  local probe_exit=0
  wait "$probe_pid" || probe_exit=$?
  (( probe_exit == 0 )) || {
    local probe_error="$(<"$error_file")"
    [[ -n "$probe_error" ]] || probe_error="exit $probe_exit"
    codex_runtime_die "installed runtime app-server probe failed: $probe_error"
  }

  [[ "$(print -rn -- "$initialize_response" | \
      /usr/bin/plutil -extract result.codexHome raw -o - - 2>/dev/null)" == "$codex_home" ]] ||
    codex_runtime_die "installed runtime app-server did not honor the isolated CODEX_HOME"
  [[ "$(/usr/bin/stat -f %Lp "$codex_home")" == "700" ]] ||
    codex_runtime_die "installed runtime state directory is not private"
)
