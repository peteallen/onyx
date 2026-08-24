#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
release_workflow="$repo_root/.github/workflows/release.yml"
ci_workflow="$repo_root/.github/workflows/ci.yml"
verify_dmg_script="$repo_root/scripts/verify-dmg.sh"
create_dmg_script="$repo_root/scripts/create-dmg.sh"
release_script="$repo_root/scripts/release.sh"
readme="$repo_root/README.md"

die() {
  print -u2 -- "check-release-automation: $*"
  exit 1
}

require_regular_file() {
  [[ -f "$1" && ! -L "$1" ]] || die "missing regular file: $1"
}

require_text() {
  local text="$1"
  local expected="$2"
  local label="$3"
  [[ "$text" == *"$expected"* ]] || die "missing $label"
}

forbid_text() {
  local text="$1"
  local forbidden="$2"
  local label="$3"
  [[ "$text" != *"$forbidden"* ]] || die "found forbidden $label"
}

require_regular_file "$release_workflow"
require_regular_file "$ci_workflow"
require_regular_file "$readme"
for script in release.sh create-dmg.sh verify-dmg.sh; do
  script_path="$repo_root/scripts/$script"
  require_regular_file "$script_path"
  [[ -x "$script_path" ]] || die "release helper is not executable: $script_path"
  "$script_path" --help >/dev/null
done

release_text="$(<"$release_workflow")"
ci_text="$(<"$ci_workflow")"
verify_dmg_text="$(<"$verify_dmg_script")"
create_dmg_text="$(<"$create_dmg_script")"
release_script_text="$(<"$release_script")"
readme_text="$(<"$readme")"

# A public release may be cut either by pushing an immutable semver tag or by
# dispatching from the current default branch. Keep the set of triggers small
# and visible so a later edit cannot silently publish arbitrary feature code.
trigger_names=()
inside_triggers=0
while IFS= read -r line; do
  if [[ "$line" == "on:" ]]; then
    inside_triggers=1
    continue
  fi
  if (( inside_triggers == 1 )) && [[ "$line" != [[:space:]]* ]]; then
    break
  fi
  if (( inside_triggers == 1 )) && \
     [[ "$line" =~ '^  ([A-Za-z_][A-Za-z0-9_]*):' ]]; then
    trigger_names+=("${match[1]}")
  fi
done < "$release_workflow"
(( ${#trigger_names[@]} == 2 )) || \
  die "release workflow must have exactly push and workflow_dispatch triggers"
[[ "${trigger_names[*]}" == "push workflow_dispatch" ]] || \
  die "release triggers must be push then workflow_dispatch"
require_text "$release_text" "  push:" "semver tag trigger"
require_text "$release_text" "    tags:" "semver tag trigger"
require_text "$release_text" "- 'v*.*.*'" "tag version filter"
require_text "$release_text" "workflow_dispatch:" "manual release trigger"
require_text "$release_text" "permissions:" "release permissions block"
require_text "$release_text" "  contents: write" \
  "write permission for public release assets"
for marker in "issues: write" "packages: write" "id-token: write" \
  "pull-requests: write" "actions: write"; do
  forbid_text "$release_text" "$marker" "unnecessary permission '$marker'"
done

# The release is intentionally an ad-hoc/unnotarized development distribution;
# no selectable source may gain access to an Apple private key in this job.
for marker in 'secrets.' 'security import' 'APPLE_DEVELOPER_ID' 'APPLE_NOTARY' \
  'notarytool' 'ONYX_NOTARIZE' 'ONYX_CODESIGN_IDENTITY'; do
  forbid_text "$release_text" "$marker" "release secret/signing marker '$marker'"
done
require_text "$release_text" "ad-hoc signed" "ad-hoc distribution disclosure"
require_text "$release_text" "not notarized" "notarization disclosure"

# Source and version gates: checkout is pinned to the event SHA, manual runs
# are main-only, tags cannot be moved, and the tag target is checked again after
# GitHub creates the release.
for marker in \
  'ref: ${{ github.sha }}' \
  'EVENT_NAME: ${{ github.event_name }}' \
  'SOURCE_SHA: ${{ github.sha }}' \
  'refs/heads/$DEFAULT_BRANCH' \
  'git ls-remote origin "refs/heads/$DEFAULT_BRANCH"' \
  'git ls-remote --exit-code origin "refs/tags/$tag"' \
  'git rev-parse "$tag^{commit}"' \
  'support/Info.plist' \
  'checked_out_sha="$(/usr/bin/git rev-parse HEAD)"'; do
  require_text "$release_text" "$marker" "immutable source/version gate '$marker'"
done
require_text "$release_text" 'gh release view "$tag"' \
  "pre-existing release rejection"
require_text "$release_text" 'gh release create' "public release creation"
require_text "$release_text" 'GH_TOKEN: ${{ github.token }}' \
  "scoped GitHub release token"
require_text "$release_text" '--target "$SOURCE_SHA"' \
  "manual release exact target"
require_text "$release_text" '--verify-tag' "tag release exact target"
require_text "$release_text" '--latest' "latest release designation"
require_text "$release_text" '--fail-on-no-commits' "no-empty-release guard"
require_text "$release_text" 'isDraft,isPrerelease,assets,url' \
  "public release postcondition query"
require_text "$release_text" "'.isDraft')\" == \"false\"" \
  "non-draft release postcondition"
require_text "$release_text" "'.isPrerelease')\" == \"false\"" \
  "non-prerelease release postcondition"
require_text "$release_text" 'releases/latest' "latest release endpoint"
require_text "$release_text" "--jq '.tag_name'" \
  "latest release postcondition"
require_text "$release_text" "Release must contain exactly two assets" \
  "exact asset count postcondition"
require_text "$release_text" 'Published digest does not match' \
  "published asset digest verification"
require_text "$release_text" 'ARTIFACT_NAME.dmg.sha256' \
  "checksum asset name"
require_text "$release_text" 'releases/download/' "direct public DMG URL"
require_text "$release_text" 'GITHUB_STEP_SUMMARY' "public download summary"
for forbidden in '--draft' 'gh release edit' 'gh release upload' '--clobber' \
  'latest/nightly' 'force push'; do
  forbid_text "$release_text" "$forbidden" "mutable release operation '$forbidden'"
done
for forbidden in 'actions/upload-artifact@' 'actions/download-artifact@' \
  'retention-days:'; do
  forbid_text "$release_text" "$forbidden" "expiring workflow artifact path '$forbidden'"
done

require_text "$release_text" "scripts/check-release-automation.sh" \
  "release contract self-check"
require_text "$release_text" \
  "scripts/fetch-codex-runtime.sh --architectures universal" \
  "universal pinned-runtime fetch"
require_text "$release_text" "scripts/release.sh" "verified release helper invocation"
require_text "$release_text" '--build-number "$GITHUB_RUN_NUMBER"' \
  "workflow-owned build number"
require_text "$release_script_text" "--signing-identity" "release signing override"
require_text "$release_script_text" "--no-notarize" "release notarization override"
for workflow_text in "$release_text" "$ci_text"; do
  require_text "$workflow_text" "--display-name Onyx" "fixed Onyx display name"
  require_text "$workflow_text" "--bundle-id app.onyx.agent" "fixed Onyx bundle ID"
  require_text "$workflow_text" "--architectures universal" "explicit universal release build"
  require_text "$workflow_text" "--signing-identity -" "explicit ad-hoc signing"
  require_text "$workflow_text" "--no-notarize" "explicitly disabled notarization"
done
require_text "$release_text" ".dmg" "DMG release asset"
require_text "$release_text" ".dmg.sha256" "DMG checksum release asset"
require_text "$readme_text" \
  "https://github.com/peteallen/onyx/releases/latest" \
  "obvious latest public download link"

# Third-party actions execute in the release trust boundary. Require immutable
# commit pins while retaining the human-readable major-version comment.
uses_pattern='@[0-9a-f]{40}([[:space:]]+#.*)?$'
for workflow_name workflow_text in release "$release_text" CI "$ci_text"; do
  uses_lines=("${(@f)$(print -r -- "$workflow_text" | /usr/bin/sed -n '/^[[:space:]]*uses:/p')}")
  (( ${#uses_lines[@]} > 0 )) || die "$workflow_name workflow has no pinned actions"
  for uses_line in "${uses_lines[@]}"; do
    [[ "$uses_line" =~ $uses_pattern ]] || \
      die "$workflow_name action is not pinned to a full commit SHA: ${uses_line##[[:space:]]#}"
  done
done

for marker in "scripts/run-preview.sh" "swift run" "open -a" "open --"; do
  forbid_text "$release_text" "$marker" "application launch marker '$marker'"
done
require_text "$ci_text" "scripts/check-release-automation.sh" \
  "CI enforcement of the release contract"

# The standalone verifier must be safe for a downloaded ad-hoc image: validate
# the real app directory and requested identity before it can execute anything
# from the mount. Local packaging opts into the helper startup proof explicitly.
require_text "$verify_dmg_text" '[[ -d "$app_path" && ! -L "$app_path" ]]' \
  "real non-symlink app payload check"
require_text "$verify_dmg_text" "--probe-runtime" "opt-in runtime probe flag"
require_text "$create_dmg_text" "--probe-runtime" "packaging runtime probe opt-in"
metadata_check_line="$(/usr/bin/awk '/^verify_plist_value CFBundleIdentifier/ { print NR; exit }' "$verify_dmg_script")"
runtime_probe_line="$(/usr/bin/awk '/^[[:space:]]*codex_runtime_probe_installed_package/ { print NR; exit }' "$verify_dmg_script")"
[[ "$metadata_check_line" == <1-> && "$runtime_probe_line" == <1-> ]] || \
  die "could not locate verifier metadata and runtime-probe checks"
[[ "$metadata_check_line" -lt "$runtime_probe_line" ]] || \
  die "verifier can execute the mounted helper before checking product identity"

print -- "Release automation checks passed: immutable-source public DMG workflow"
