#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
preview_script="$repo_root/scripts/package-preview.sh"
package_app_script="$repo_root/scripts/package-app.sh"
run_script="$repo_root/scripts/run-preview.sh"
repair_script="$repo_root/scripts/repair-preview-registration.sh"
preview_app="$repo_root/dist-preview/Onyx Preview.app"
runtime_common_script="$repo_root/scripts/codex-runtime-common.sh"
runtime_manifest="$repo_root/support/codex-runtime-manifest.json"

script_text="$(<"$preview_script")"
[[ "$script_text" == *'preview_app="$repo_root/dist-preview/Onyx Preview.app"'* ]]
[[ "$script_text" == *'preview_bundle_identifier="app.onyx.preview"'* ]]
[[ "$script_text" == *'preview_display_name="Onyx Preview"'* ]]
[[ "$script_text" == *'preview_build_number="$(/bin/date -u +%Y%m%d%H%M%S)"'* ]]
[[ "$script_text" == *'stable_signing_identity="71E83D4C74C2320E54ABA79ABA79B2D75B8A1B8A"'* ]]
[[ "$script_text" == *'"$repo_root/scripts/package-app.sh" "${package_arguments[@]}"'* ]]
[[ "$script_text" != *'security find-identity -v -p codesigning'* ]]
[[ "$script_text" == *'the preview signing identity is empty'* ]]
[[ "$script_text" == *'ONYX_PREVIEW_CODESIGN_IDENTITY to a certificate fingerprint'* ]]
[[ "$script_text" == *'refusing to operate through a symbolic link'* ]]
[[ "$script_text" == *'lsof_pids_or_die -a -d txt -t -- "$preview_executable"'* ]]
[[ "$script_text" == *'lsof_pids_or_die -a -p "$preview_pid" -d txt -t --'* ]]
[[ "$script_text" == *'could not inspect the preview process'* ]]
[[ "$script_text" == *'/bin/kill -TERM "$preview_pid"'* ]]
[[ "$script_text" != *'pkill'* && "$script_text" != *'killall'* && \
   "$script_text" != *'/bin/kill -KILL'* ]]

# The replacement must be fully packaged and verified at its private sibling
# path before the canonical preview can receive TERM, and only that prepared
# bundle may enter the atomic swap.
package_preparation_line="$(/usr/bin/awk \
  '/^"\$repo_root\/scripts\/package-app\.sh"/ { print NR; exit }' "$preview_script")"
package_stop_line="$(/usr/bin/awk \
  '/if ! \/bin\/kill -TERM/ { print NR; exit }' "$preview_script")"
package_swap_line="$(/usr/bin/awk \
  '/atomic-swap\.swift/ { print NR; exit }' "$preview_script")"
[[ "$package_preparation_line" == <1-> && "$package_stop_line" == <1-> && \
   "$package_swap_line" == <1-> ]]
[[ "$package_preparation_line" -lt "$package_stop_line" ]]
[[ "$package_stop_line" -lt "$package_swap_line" ]]
[[ "$script_text" == *'"$repo_root/scripts/package-app.sh" "${package_arguments[@]}"'* ]]
[[ "$script_text" == *'debug
  "$prepared_app"'* ]]
[[ "$script_text" == *'atomic-swap.swift" "$preview_app" "$prepared_app"'* ]]
[[ "$script_text" != *'package-app.sh" "${package_arguments[@]}" --allow-running-overwrite'* ]]

run_text="$(<"$run_script")"
[[ "$run_text" == *'"$repo_root/scripts/package-preview.sh" --stop-running'* ]]
[[ "$run_text" == *'"$repo_root/scripts/repair-preview-registration.sh"'* ]]
[[ "$run_text" == *'/usr/bin/open "$preview_app"'* ]]
[[ "$run_text" == *'-h|--help)'* ]]
[[ "$run_text" != *'open -n'* ]]
[[ "$run_text" == *'lsof_fields_or_die -a -c Onyx -d txt -Fpn'* ]]
[[ "$run_text" == *'lsof_fields_or_die -a -d txt -t --'* ]]
[[ "$run_text" == *'could not inspect running apps'* ]]
[[ "$run_text" == *'preview_pids[(Ie)$process_pid]'* ]]
[[ "$run_text" == *'quit the other Onyx process yourself; no noncanonical process was stopped'* ]]
[[ "$run_text" == *'run_preview_lock_file="$repo_root/dist-preview/.run-preview.lock"'* ]]
[[ "$run_text" == *'/usr/bin/lockf -s -t 0 9'* ]]
[[ "$run_text" == *'another run-preview invocation is already packaging or launching'* ]]
[[ "$run_text" != *'pkill'* && "$run_text" != *'killall'* && \
   "$run_text" != *'/bin/kill'* ]]
[[ "$run_text" == *$'acquire_run_preview_lock\n\n  # Check before packaging'* ]]
[[ "$run_text" == *$'guard_against_other_onyx_processes\n\n  "$repo_root/scripts/package-preview.sh" --stop-running'* ]]
[[ "$run_text" == *$'"$repo_root/scripts/package-preview.sh" --stop-running\n\n  # Remove LaunchServices registrations'* ]]
[[ "$run_text" == *$'"$repo_root/scripts/repair-preview-registration.sh"\n\n  # Close the packaging race'* ]]

# Source only the auditable field parser. run-preview's main guard must prevent
# package, stop, or open side effects when the contract test imports it.
ONYX_RUN_PREVIEW_LIBRARY_ONLY=1
source "$run_script"
unset ONYX_RUN_PREVIEW_LIBRARY_ONLY

# Hold the launch lock in a short-lived fixture process, then prove a sourced
# launcher fails immediately without reaching package, registration, or open.
lock_fixture_dir="$(/usr/bin/mktemp -d \
  "${TMPDIR:-/tmp}/onyx-run-preview-lock.XXXXXX")"
run_preview_lock_file="$lock_fixture_dir/run-preview.lock"
lock_fixture_ready="$lock_fixture_dir/ready"
lock_fixture_release="$lock_fixture_dir/release"
# Restricted macOS runners can deny the harmless priority adjustment zsh
# normally applies to background jobs. The lock contract does not depend on
# priority, so disable that shell behavior for this fixture.
unsetopt BG_NICE
/usr/bin/lockf -s -t 0 "$run_preview_lock_file" /bin/zsh -c '
  /usr/bin/touch "$1"
  for attempt in {1..500}; do
    [[ -e "$2" ]] && exit 0
    /bin/sleep 0.01
  done
  exit 1
' onyx-lock-holder "$lock_fixture_ready" "$lock_fixture_release" &
lock_fixture_pid=$!
for attempt in {1..100}; do
  [[ -e "$lock_fixture_ready" ]] && break
  /bin/sleep 0.01
done
if [[ ! -e "$lock_fixture_ready" ]]; then
  /usr/bin/touch "$lock_fixture_release"
  wait "$lock_fixture_pid" 2>/dev/null || true
  /bin/rm -rf -- "$lock_fixture_dir"
  print -u2 -- "check-package-preview: launch-lock fixture did not become ready"
  exit 1
fi

lock_contention_output=""
lock_contention_succeeded=0
if lock_contention_output="$(acquire_run_preview_lock 2>&1)"; then
  lock_contention_succeeded=1
fi
/usr/bin/touch "$lock_fixture_release"
lock_fixture_failed=0
wait "$lock_fixture_pid" || lock_fixture_failed=1
/bin/rm -rf -- "$lock_fixture_dir"
run_preview_lock_file="$repo_root/dist-preview/.run-preview.lock"

if (( lock_contention_succeeded == 1 )); then
  print -u2 -- "check-package-preview: concurrent launcher unexpectedly acquired the lock"
  exit 1
fi
if (( lock_fixture_failed == 1 )); then
  print -u2 -- "check-package-preview: launch-lock fixture failed"
  exit 1
fi
[[ "$lock_contention_output" == *'another run-preview invocation is already packaging or launching'* ]]

process_fixture=$'p101\nftxt\nn/tmp/OnyxPackageTests.xctest\n'\
$'p202\nftxt\nn/tmp/repo/.build/arm64-apple-macosx/debug/Onyx\n'\
$'p303\nftxt\nn/tmp/repo/dist/Onyx.app/Contents/MacOS/Onyx\n'\
$'p404\nftxt\nn/tmp/repo/dist-preview/Onyx Preview.app/Contents/MacOS/Onyx'
expected_records=$'202\t/tmp/repo/.build/arm64-apple-macosx/debug/Onyx\n'\
$'303\t/tmp/repo/dist/Onyx.app/Contents/MacOS/Onyx\n'\
$'404\t/tmp/repo/dist-preview/Onyx Preview.app/Contents/MacOS/Onyx'
[[ "$(onyx_process_records "$process_fixture")" == "$expected_records" ]]

# Exercise the refusal path without starting a process or invoking the real
# package/open commands. The guard must name the conflicting PID/path and exit.
guard_output=""
if guard_output="$(
  (
    other_onyx_processes() {
      print -r -- $'505\t/tmp/repo/dist/Onyx.app/Contents/MacOS/Onyx'
    }
    guard_against_other_onyx_processes
  ) 2>&1
)"; then
  print -u2 -- "check-package-preview: conflicting Onyx process unexpectedly passed"
  exit 1
fi
[[ "$guard_output" == *'PID 505: /tmp/repo/dist/Onyx.app/Contents/MacOS/Onyx'* ]]
[[ "$guard_output" == *'no noncanonical process was stopped'* ]]

(
  other_onyx_processes() { return 0 }
  guard_against_other_onyx_processes
)

# A normal lsof no-match is status 1 without stderr. A higher silent failure or
# any diagnostic must fail closed; otherwise the launch guard could mistake an
# inspection failure for an empty process list.
(
  function /usr/sbin/lsof { return 1 }
  [[ -z "$(lsof_fields_or_die -a -c Onyx -d txt -Fpn)" ]]
)

silent_lsof_failure=""
if silent_lsof_failure="$(
  (
    function /usr/sbin/lsof { return 7 }
    lsof_fields_or_die -a -c Onyx -d txt -Fpn
  ) 2>&1
)"; then
  print -u2 -- "check-package-preview: silent lsof failure unexpectedly passed"
  exit 1
fi
[[ "$silent_lsof_failure" == *'lsof exited with status 7'* ]]

diagnostic_lsof_failure=""
if diagnostic_lsof_failure="$(
  (
    function /usr/sbin/lsof {
      print -u2 -- "fixture inspection failed"
      return 1
    }
    lsof_fields_or_die -a -c Onyx -d txt -Fpn
  ) 2>&1
)"; then
  print -u2 -- "check-package-preview: diagnostic lsof failure unexpectedly passed"
  exit 1
fi
[[ "$diagnostic_lsof_failure" == *'fixture inspection failed'* ]]

partial_lsof_failure=""
if partial_lsof_failure="$(
  (
    function /usr/sbin/lsof {
      print -r -- $'p606\nftxt\nn/tmp/repo/dist/Onyx.app/Contents/MacOS/Onyx'
      return 1
    }
    lsof_fields_or_die -a -c Onyx -d txt -Fpn
  ) 2>&1
)"; then
  print -u2 -- "check-package-preview: partial lsof failure unexpectedly passed"
  exit 1
fi
[[ "$partial_lsof_failure" == *'lsof exited with status 1'* ]]

package_app_text="$(<"$package_app_script")"
runtime_common_text="$(<"$runtime_common_script")"
[[ "$package_app_text" == *'target_running_pids()'* ]]
[[ "$package_app_text" == *'final_running_pids="$(target_running_pids)"'* ]]
[[ "$package_app_text" == *'target started running during packaging'* ]]
[[ "$package_app_text" == *'could not inspect the package target'* ]]
[[ "$package_app_text" == *'source "$repo_root/scripts/codex-runtime-common.sh"'* ]]
[[ "$package_app_text" == *'codex_runtime_validate_archive'* ]]
[[ "$package_app_text" == *'Helpers/CodexRuntime'* ]]
[[ "$package_app_text" == *'nested_codesign_arguments'* ]]
[[ "$package_app_text" != *'/usr/bin/codesign --deep'* ]]
[[ "$runtime_common_text" == *'ONYX_CODEX_RUNTIME_ARCHIVE_ARM64'* ]]
[[ "$runtime_common_text" == *'ONYX_CODEX_RUNTIME_ARCHIVE_X86_64'* ]]
[[ "$runtime_common_text" == *'contains a symlink, hard link, or unsupported entry'* ]]
# The async app-server probe must create its redirected files itself before it
# starts the helper. Otherwise the polling reader can win the scheduling race
# and abort under `set -e` because output.jsonl does not exist yet.
runtime_output_precreate_line="$(/usr/bin/awk \
  'index($0, ": >| \"$output_file\"") { print NR; exit }' "$runtime_common_script")"
runtime_error_precreate_line="$(/usr/bin/awk \
  'index($0, ": >| \"$error_file\"") { print NR; exit }' "$runtime_common_script")"
runtime_probe_launch_line="$(/usr/bin/awk \
  '/local probe_pid=\$!/ { print NR; exit }' "$runtime_common_script")"
runtime_probe_read_line="$(/usr/bin/awk \
  '/done < "\$output_file"/ { print NR; exit }' "$runtime_common_script")"
[[ "$runtime_output_precreate_line" == <1-> && \
   "$runtime_error_precreate_line" == <1-> && \
   "$runtime_probe_launch_line" == <1-> && "$runtime_probe_read_line" == <1-> ]]
[[ "$runtime_output_precreate_line" -lt "$runtime_probe_launch_line" && \
   "$runtime_error_precreate_line" -lt "$runtime_probe_launch_line" && \
   "$runtime_probe_launch_line" -lt "$runtime_probe_read_line" ]]
[[ "$(/usr/bin/plutil -extract version raw -o - "$runtime_manifest")" == "0.149.0" ]]
[[ "$(/usr/bin/plutil -extract artifacts.0.target raw -o - "$runtime_manifest")" == \
  "aarch64-apple-darwin" ]]
[[ "$(/usr/bin/plutil -extract artifacts.1.target raw -o - "$runtime_manifest")" == \
  "x86_64-apple-darwin" ]]

repair_text="$(<"$repair_script")"
[[ "$repair_text" == *'app.onyx.preview.b'* ]]
[[ "$repair_text" == *'"$repo_root"/dist*/**/*.app(N)'* ]]
[[ "$repair_text" == *'dev.peteallen.onyx.*'* ]]
[[ "$repair_text" == *'com.peteallen.onyx'* ]]
[[ "$repair_text" == *'com.peteallen.onyx.preview'* ]]
[[ "$repair_text" == *'candidate" == "$stable_app"'* ]]
[[ "$repair_text" == *'canonical preview bundle identifier is not app.onyx.preview'* ]]
[[ "$repair_text" == *'lsregister" -u "$old_app"'* ]]
[[ "$repair_text" == *'lsregister" -f "$stable_app"'* ]]
[[ "$repair_text" != *'lsregister" -delete'* ]]
[[ "$repair_text" != *'/bin/rm'* && "$repair_text" != *'rm -rf'* ]]

if "$preview_script" --unknown-option >/dev/null 2>&1; then
  print -u2 -- "check-package-preview: unknown option unexpectedly succeeded"
  exit 1
fi

print -- "Stable preview contract checks passed"
