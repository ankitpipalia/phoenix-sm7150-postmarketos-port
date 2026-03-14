#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pmbootstrap_py="$workspace_root/pmbootstrap/pmbootstrap.py"
pmbootstrap_cfg="$workspace_root/pmbootstrap.cfg"
pmaports_dir="$workspace_root/pmaports"
work_dir="$workspace_root/.pmbootstrap"

if [[ -f "$pmbootstrap_py" ]]; then
	exec python3 "$pmbootstrap_py" \
		-c "$pmbootstrap_cfg" \
		-p "$pmaports_dir" \
		-w "$work_dir" \
		"$@"
fi

exec pmbootstrap \
	-c "$pmbootstrap_cfg" \
	-p "$pmaports_dir" \
	-w "$work_dir" \
	"$@"
