#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
preview_app="$repo_root/dist-preview/Onyx Preview.app"

"$repo_root/scripts/package-preview.sh" --stop-running

# Launch by the one stable bundle path. package-preview has already stopped the
# exact previous executable; parallel instances would duplicate its app-server.
/usr/bin/open "$preview_app"
