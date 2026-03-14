#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"

# Default to this workspace's pmbootstrap workdir. Caller can override with arg.
pmb_dir="${1:-$workspace_root/.pmbootstrap}"

if [[ -x "$repo_root/scripts/pmbootstrap-phoenix.sh" ]]; then
	"$repo_root/scripts/pmbootstrap-phoenix.sh" shutdown >/dev/null 2>&1 || true
elif command -v pmbootstrap >/dev/null 2>&1; then
	pmbootstrap shutdown >/dev/null 2>&1 || true
fi

if [[ -d "$pmb_dir" ]]; then
	rm -rf "$pmb_dir"
	echo "Removed pmbootstrap state: $pmb_dir"
else
	echo "pmbootstrap state directory not found: $pmb_dir"
fi
