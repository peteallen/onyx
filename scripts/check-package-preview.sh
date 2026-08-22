#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
preview_script="$repo_root/scripts/package-preview.sh"
package_app_script="$repo_root/scripts/package-app.sh"
run_script="$repo_root/scripts/run-preview.sh"
repair_script="$repo_root/scripts/repair-preview-registration.sh"
preview_app="$repo_root/dist-preview/Onyx Preview.app"

script_text="$(<"$preview_script")"
[[ "$script_text" == *'preview_app="$repo_root/dist-preview/Onyx Preview.app"'* ]]
[[ "$script_text" == *'preview_bundle_identifier="app.onyx.preview"'* ]]
[[ "$script_text" == *'preview_display_name="Onyx Preview"'* ]]
[[ "$script_text" == *'preview_build_number="$(/bin/date -u +%Y%m%d%H%M%S)"'* ]]
[[ "$script_text" == *'security find-identity -v -p codesigning'* ]]
[[ "$script_text" == *'signing_identity="${match[1]}"'* ]]
[[ "$script_text" == *'no valid code-signing identity found'* ]]
[[ "$script_text" == *'ONYX_PREVIEW_CODESIGN_IDENTITY to a certificate fingerprint'* ]]
[[ "$script_text" == *'refusing to operate through a symbolic link'* ]]
[[ "$script_text" == *'/usr/sbin/lsof -a -d txt -t -- "$preview_executable"'* ]]
[[ "$script_text" == *'/usr/sbin/lsof -a -p "$preview_pid" -d txt -t --'* ]]
[[ "$script_text" == *'/bin/kill -TERM "$preview_pid"'* ]]
[[ "$script_text" != *'pkill'* && "$script_text" != *'killall'* && \
   "$script_text" != *'/bin/kill -KILL'* ]]

run_text="$(<"$run_script")"
[[ "$run_text" == *'"$repo_root/scripts/package-preview.sh" --stop-running'* ]]
[[ "$run_text" == *'/usr/bin/open "$preview_app"'* ]]
[[ "$run_text" != *'open -n'* ]]

package_app_text="$(<"$package_app_script")"
[[ "$package_app_text" == *'target_running_pids()'* ]]
[[ "$package_app_text" == *'final_running_pids="$(target_running_pids)"'* ]]
[[ "$package_app_text" == *'target started running during packaging'* ]]

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
