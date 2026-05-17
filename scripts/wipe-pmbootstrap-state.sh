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
	# Refuse to delete a directory that doesn't look like a pmbootstrap
	# workdir, so an accidental arg (or repo-cwd misresolution) can't take
	# out an unrelated $HOME directory. A pmbootstrap workdir always
	# contains a `config` file or a `chroot_native` subdir.
	if [[ ! -e "$pmb_dir/config" && ! -d "$pmb_dir/chroot_native" ]]; then
		echo "Refusing to delete $pmb_dir: does not look like a pmbootstrap workdir" >&2
		echo "Expected one of: $pmb_dir/config or $pmb_dir/chroot_native" >&2
		exit 1
	fi
	rm -rf "$pmb_dir"
	echo "Removed pmbootstrap state: $pmb_dir"
else
	echo "pmbootstrap state directory not found: $pmb_dir"
fi
