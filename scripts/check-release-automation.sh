#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
release_workflow="$repo_root/.github/workflows/release.yml"
ci_workflow="$repo_root/.github/workflows/ci.yml"
verify_dmg_script="$repo_root/scripts/verify-dmg.sh"
create_dmg_script="$repo_root/scripts/create-dmg.sh"
release_script="$repo_root/scripts/release.sh"
readme="$repo_root/README.md"
info_plist="$repo_root/support/Info.plist"

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
require_regular_file "$info_plist"
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
declared_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"

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

# Source and version gates: checkout is pinned to the event SHA, every new tag
# created from an untagged source requires the current main head at both
# mutation boundaries, and manual tags are created atomically only after the
# verified artifact is ready. Exact existing tags are reusable only at that
# same current source; existing releases are rechecked, never replaced.
for marker in \
  'ref: ${{ github.sha }}' \
  'EVENT_NAME: ${{ github.event_name }}' \
  'SOURCE_SHA: ${{ github.sha }}' \
  'refs/heads/$DEFAULT_BRANCH' \
  '[[ "$tag" =~ '\''^v[0-9]+[.][0-9]+[.][0-9]+$'\'' ]]' \
  'repos/$GITHUB_REPOSITORY/branches/$DEFAULT_BRANCH' \
  'git ls-remote --exit-code origin "refs/tags/$tag"' \
  'git rev-parse "$tag^{commit}"' \
  '[[ "$main_sha" == "$SOURCE_SHA" ]]' \
  'support/Info.plist' \
  'checked_out_sha="$(/usr/bin/git rev-parse HEAD)"'; do
  require_text "$release_text" "$marker" "immutable source/version gate '$marker'"
done
require_text "$release_text" 'gh release view "$TAG"' \
  "exact existing-release recheck"
require_text "$release_text" 'gh release create' "public release creation"
require_text "$release_text" 'GH_TOKEN: ${{ github.token }}' \
  "scoped GitHub release token"
require_text "$release_text" 'git/refs' "atomic manual tag creation"
require_text "$release_text" 'ref=refs/tags/$TAG' \
  "manual tag source ref"
require_text "$release_text" 'sha=$SOURCE_SHA' \
  "manual tag source SHA"
require_text "$release_text" 'resolve_tag_commit()' \
  "authenticated exact tag resolution"
require_text "$release_text" 'commits/$tag_name' \
  "tag-to-commit dereference"
require_text "$release_text" 'if ! gh api --method POST' \
  "atomic tag-create race handling"
require_text "$release_text" 'for attempt in {1..6}' \
  "bounded tag visibility retry"
require_text "$release_text" '--verify-tag' "tag release exact target"
require_text "$release_text" '--latest' "latest release designation"
require_text "$release_text" '--fail-on-no-commits' "no-empty-release guard"
require_text "$release_text" 'isDraft,isPrerelease,assets,body,url' \
  "source-commit release postcondition query"
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
require_text "$release_text" 'gh release download "$TAG"' \
  "exact-release retry asset verification"
require_text "$release_text" 'release_reused=false' \
  "explicit exact-release retry state"
require_text "$release_text" 'if [[ "$release_reused" == "true" ]]; then' \
  "separate retry asset verification"
require_text "$release_text" 'Existing release digest does not match' \
  "reused asset digest verification"
require_text "$release_text" 'shasum -a 256 -c "$existing_checksum"' \
  "reused checksum pair verification"
require_text "$release_text" 'scripts/verify-dmg.sh "$existing_dmg"' \
  "reused DMG product verification"
require_text "$release_text" '--source-revision "$GITHUB_SHA"' \
  "release source revision embedding and verification"
for marker in \
  'assert_clean_source()' \
  'assert_current_main()' \
  '/usr/bin/git diff-index --quiet HEAD --' \
  '/usr/bin/git status --porcelain --untracked-files=all' \
  'repos/$GITHUB_REPOSITORY/branches/$DEFAULT_BRANCH' \
  '[[ "$current_main_sha" == "$SOURCE_SHA" ]]'; do
  require_text "$release_text" "$marker" "late release source gate '$marker'"
done
require_text "$release_text" 'ARTIFACT_NAME.dmg.sha256' \
  "checksum asset name"
require_text "$release_text" 'releases/download/' "direct public DMG URL"
require_text "$release_text" 'GITHUB_STEP_SUMMARY' "public download summary"
for forbidden in '--draft' '--target' 'gh release edit' 'gh release upload' '--clobber' \
  'latest/nightly' 'force push'; do
  forbid_text "$release_text" "$forbidden" "mutable release operation '$forbidden'"
done

artifact_gate_line="$(/usr/bin/awk '/Release DMG\/checksum pair is incomplete/ { print NR; exit }' "$release_workflow")"
clean_assertion_line="$(/usr/bin/awk '/^[[:space:]]+assert_clean_source$/ { print NR; exit }' "$release_workflow")"
main_assertion_lines=("${(@f)$(/usr/bin/awk '/^[[:space:]]+assert_current_main$/ { print NR }' "$release_workflow")}")
tag_create_line="$(/usr/bin/awk '/gh api --method POST/ { print NR; exit }' "$release_workflow")"
release_check_line="$(/usr/bin/awk '/^[[:space:]]+if ! gh release view "\$TAG" --repo "\$GITHUB_REPOSITORY" >\/dev\/null 2>&1; then$/ { print NR; exit }' "$release_workflow")"
release_create_line="$(/usr/bin/awk '/if ! gh release create/ { print NR; exit }' "$release_workflow")"
[[ "$artifact_gate_line" == <1-> && "$tag_create_line" == <1-> && \
   "$release_check_line" == <1-> && \
   "$release_create_line" == <1-> && \
   "$tag_create_line" -gt "$artifact_gate_line" ]] || \
  die "manual tag creation must follow the verified artifact gate"
[[ "$clean_assertion_line" == <1-> && "$clean_assertion_line" -gt "$artifact_gate_line" ]] || \
  die "release publication must verify the immutable checkout after the artifact gate"
(( ${#main_assertion_lines[@]} == 2 )) || \
  die "release publication must perform exactly two current-main mutation assertions"
[[ "${main_assertion_lines[1]}" -lt "$tag_create_line" && \
   "$tag_create_line" -lt "${main_assertion_lines[2]}" && \
   "${main_assertion_lines[2]}" -lt "$release_check_line" && \
   "$release_check_line" -lt "$release_create_line" ]] || \
  die "current-main assertions must guard manual tag creation and every release/reuse path"
(( tag_create_line - main_assertion_lines[1] <= 2 )) || \
  die "manual tag creation must immediately follow a current-main assertion"
(( release_check_line - main_assertion_lines[2] <= 2 )) || \
  die "the current-main gate must immediately precede the release create/reuse decision"
forbid_text "$release_text" 'if [[ "$tag_created_this_run" == "true" ]]; then' \
  "conditional current-main release gate"
require_text "$release_text" \
  'if ! gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then' \
  "fresh existing-release check"
require_text "$release_text" \
  'gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || exit 1' \
  "safe release-create race recovery"
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
require_text "$ci_text" '--source-revision "$GITHUB_SHA"' \
  "CI source revision embedding and verification"
for script_text in "$release_script_text" "$verify_dmg_text"; do
  require_text "$script_text" "--source-revision" \
    "source revision packaging/verifier option"
done
require_text "$release_text" ".dmg" "DMG release asset"
require_text "$release_text" ".dmg.sha256" "DMG checksum release asset"
require_text "$readme_text" \
  "https://github.com/peteallen/onyx/releases/latest" \
  "obvious latest public download link"
require_text "$readme_text" \
  "https://github.com/peteallen/onyx/releases/download/v$declared_version/Onyx-$declared_version-macOS.dmg" \
  "direct DMG link matching support/Info.plist"
require_text "$readme_text" \
  "https://github.com/peteallen/onyx/releases/download/v$declared_version/Onyx-$declared_version-macOS.dmg.sha256" \
  "direct checksum link matching support/Info.plist"

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
