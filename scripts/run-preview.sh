#!/bin/zsh
set -euo pipefail

run_preview_eval_context="$ZSH_EVAL_CONTEXT"
script_path="${${(%):-%x}:A}"
repo_root="${script_path:h:h}"
preview_app="$repo_root/dist-preview/Onyx Preview.app"
preview_executable="$preview_app/Contents/MacOS/Onyx"
run_preview_lock_file="$repo_root/dist-preview/.run-preview.lock"

usage() {
  cat <<'EOF'
Build, replace, and launch the one stable Onyx preview application.

Usage:
  scripts/run-preview.sh

This command has no alternate app path or identity. It refuses to run while a
noncanonical Onyx executable is active, rebuilds only
dist-preview/Onyx Preview.app, and launches that bundle without creating a
second instance.
EOF
}

die() {
  print -u2 -- "run-preview: $*"
  exit 1
}

acquire_run_preview_lock() {
  [[ -x /usr/bin/lockf ]] || \
    die "cannot serialize preview launches because /usr/bin/lockf is unavailable"
  /bin/mkdir -p -- "${run_preview_lock_file:h}" || \
    die "could not prepare the preview launch lock"
  exec 9>> "$run_preview_lock_file" || \
    die "could not open the preview launch lock: $run_preview_lock_file"
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    die "another run-preview invocation is already packaging or launching the canonical preview"
  fi
}

lsof_fields_or_die() {
  [[ -x /usr/sbin/lsof ]] || die "cannot inspect running apps because /usr/sbin/lsof is unavailable"
  local temp_dir
  temp_dir="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/onyx-run-preview-lsof.XXXXXX")" || \
    die "could not create a private directory for process inspection"
  local output_file="$temp_dir/output"
  local error_file="$temp_dir/error"
  local lsof_exit=0

  /usr/sbin/lsof "$@" >| "$output_file" 2>| "$error_file" || lsof_exit=$?
  # lsof uses status 1 with no diagnostic for an ordinary no-match result.
  # Any diagnostic, higher silent status, or partial-output failure means
  # inspection was not trustworthy and must stop the launch.
  if [[ -s "$error_file" ]] || (( lsof_exit > 1 )) || \
     (( lsof_exit == 1 && $(/usr/bin/wc -c < "$output_file") > 0 )); then
    local diagnostic="$(<"$error_file")"
    [[ -n "$diagnostic" ]] || diagnostic="lsof exited with status $lsof_exit"
    /bin/rm -rf -- "$temp_dir"
    die "could not inspect running apps: $diagnostic"
  fi
  [[ -f "$output_file" ]] && local output="$(<"$output_file")" || local output=""
  /bin/rm -rf -- "$temp_dir"
  print -r -- "$output"
}

# Extract only real Onyx executables from lsof's process/file field stream.
# `lsof -c Onyx` is a prefix match and can also return test executables such as
# OnyxPackageTests, so the exact executable basename check is intentional.
onyx_process_records() {
  local process_fields="$1"
  local process_pid=""
  local process_executable=""
  local field

  for field in "${(f)process_fields}"; do
    case "$field" in
      p<->)
        if [[ -n "$process_pid" && "${process_executable:t}" == "Onyx" ]]; then
          print -r -- "$process_pid"$'\t'"$process_executable"
        fi
        process_pid="${field#p}"
        process_executable=""
        ;;
      n*)
        # The first text file in each lsof process record is its executable.
        [[ -n "$process_executable" ]] || process_executable="${field#n}"
        ;;
    esac
  done

  if [[ -n "$process_pid" && "${process_executable:t}" == "Onyx" ]]; then
    print -r -- "$process_pid"$'\t'"$process_executable"
  fi
}

other_onyx_processes() {
  local process_fields
  local process_records
  local current_record
  local process_pid
  local process_executable
  local -a preview_pids

  process_fields="$(lsof_fields_or_die -a -c Onyx -d txt -Fpn)"
  process_records="$(onyx_process_records "$process_fields")"
  preview_pids=()
  if [[ -f "$preview_executable" ]]; then
    # Match the exact file identity, not its spelling. This continues to
    # recognise the canonical process after package-preview atomically swaps
    # the bundle while the old process is winding down.
    preview_pids=(${(f)"$(lsof_fields_or_die -a -d txt -t -- \
      "$preview_executable")"})
  fi

  for current_record in "${(f)process_records}"; do
    process_pid="${current_record%%$'\t'*}"
    process_executable="${current_record#*$'\t'}"
    [[ "$process_pid" == <1-> ]] || continue
    (( preview_pids[(Ie)$process_pid] > 0 )) && continue
    print -r -- "$process_pid"$'\t'"$process_executable"
  done
}

guard_against_other_onyx_processes() {
  local conflicts
  local conflict
  local process_pid
  local process_executable

  conflicts="$(other_onyx_processes)"
  [[ -z "$conflicts" ]] && return 0

  print -u2 -- "run-preview: refusing to launch while another Onyx executable is running:"
  for conflict in "${(f)conflicts}"; do
    process_pid="${conflict%%$'\t'*}"
    process_executable="${conflict#*$'\t'}"
    print -u2 -- "  PID $process_pid: $process_executable"
  done
  die "quit the other Onyx process yourself; no noncanonical process was stopped"
}

main() {
  if (( $# > 0 )); then
    case "$1" in
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  fi

  # Hold one OS-managed lock across inspection, packaging, registration, and
  # opening. This closes the only remaining path for two automation workers to
  # interleave the canonical launch lifecycle. The lock is released whenever
  # this shell exits, including after an error; no stale PID file is involved.
  acquire_run_preview_lock

  # Check before packaging so a conflicting process cannot cause the stable
  # preview to be stopped as a side effect of a launch that will be refused.
  guard_against_other_onyx_processes

  "$repo_root/scripts/package-preview.sh" --stop-running

  # Remove LaunchServices registrations left by the old renamed preview
  # bundles, then force-register this one stable identity before opening it.
  # The repair is registration-only: it never deletes an app bundle or resets
  # the user's LaunchServices database.
  "$repo_root/scripts/repair-preview-registration.sh"

  # Close the packaging race: a raw `swift run` or legacy bundle could have
  # started while the stable preview was being rebuilt. Never launch beside it.
  guard_against_other_onyx_processes

  # Launch by the one stable bundle path. package-preview has already stopped
  # the exact previous executable; parallel instances would duplicate its
  # app-server.
  /usr/bin/open "$preview_app"
}

# Keep the parser sourceable by the shell contract test without packaging or
# launching an application.
if [[ "${ONYX_RUN_PREVIEW_LIBRARY_ONLY:-0}" != "1" && \
  "$run_preview_eval_context" != *:file* ]]; then
  main "$@"
fi
