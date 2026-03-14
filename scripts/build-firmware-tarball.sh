#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_default="$repo_root/firmware-xiaomi-phoenix/firmware-xiaomi-phoenix.tar.gz"

a615=""
novatek=""
output="$output_default"

usage() {
	cat <<'EOF'
Usage:
  build-firmware-tarball.sh \
    --a615-zap /path/to/a615_zap.mbn \
    --novatek-fw /path/to/novatek_nt36672c_g7b_fw01.bin \
    [--output /path/to/firmware-xiaomi-phoenix.tar.gz]
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--a615-zap)
			a615="${2:-}"
			shift 2
			;;
		--novatek-fw)
			novatek="${2:-}"
			shift 2
			;;
		--output)
			output="${2:-}"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage
			exit 1
			;;
	esac
done

if [[ -z "$a615" || -z "$novatek" ]]; then
	echo "Both --a615-zap and --novatek-fw are required." >&2
	usage
	exit 1
fi

if [[ ! -f "$a615" ]]; then
	echo "Missing input file: $a615" >&2
	exit 1
fi

if [[ ! -f "$novatek" ]]; then
	echo "Missing input file: $novatek" >&2
	exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/lib/firmware/qcom/sm7150/phoenix"
cp -a "$a615" "$tmp_dir/lib/firmware/qcom/sm7150/phoenix/a615_zap.mbn"
cp -a "$novatek" "$tmp_dir/lib/firmware/novatek_nt36672c_g7b_fw01.bin"

mkdir -p "$(dirname "$output")"
tar -C "$tmp_dir" -czf "$output" lib

echo "Created: $output"
sha512sum "$output"
