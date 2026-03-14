#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_default="$repo_root/firmware-xiaomi-phoenix/firmware-xiaomi-phoenix.tar.gz"

a615=""
novatek=""
firmware_root=""
output="$output_default"

usage() {
	cat <<'EOF'
Usage:
  # Recommended: package a fully assembled firmware tree
  build-firmware-tarball.sh \
    --firmware-root /path/with/lib/firmware \
    [--output /path/to/firmware-xiaomi-phoenix.tar.gz]

  # Minimal mode (legacy): panel + GPU only
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
		--firmware-root)
			firmware_root="${2:-}"
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ -n "$firmware_root" ]]; then
	if [[ ! -d "$firmware_root/lib/firmware" ]]; then
		echo "Expected directory missing: $firmware_root/lib/firmware" >&2
		exit 1
	fi

	cp -a "$firmware_root/lib" "$tmp_dir/"

	# These are provided by firmware-qcom-adreno-a630 in postmarketOS.
	# Remove duplicates to avoid APK file ownership conflicts.
	rm -f "$tmp_dir/lib/firmware/qcom/a630_gmu.bin"
	rm -f "$tmp_dir/lib/firmware/qcom/a630_sqe.fw"

	required=(
		"lib/firmware/qcom/sm7150/phoenix/a615_zap.mbn"
		"lib/firmware/qcom/sm7150/phoenix/adsp.mbn"
		"lib/firmware/qcom/sm7150/phoenix/cdsp.mbn"
		"lib/firmware/qcom/sm7150/phoenix/modem.mbn"
		"lib/firmware/qcom/sm7150/phoenix/wlanmdsp.mbn"
		"lib/firmware/qcom/sm7150/phoenix/ipa_fws.mbn"
		"lib/firmware/qcom/sm7150/phoenix/venus.mbn"
		"lib/firmware/novatek_nt36672c_g7b_fw01.bin"
	)
	for rel in "${required[@]}"; do
		if [[ ! -f "$tmp_dir/$rel" ]]; then
			echo "Missing required firmware file in --firmware-root: $rel" >&2
			exit 1
		fi
	done
else
	if [[ -z "$a615" || -z "$novatek" ]]; then
		echo "Either --firmware-root or both --a615-zap and --novatek-fw are required." >&2
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

	mkdir -p "$tmp_dir/lib/firmware/qcom/sm7150/phoenix"
	cp -a "$a615" "$tmp_dir/lib/firmware/qcom/sm7150/phoenix/a615_zap.mbn"
	cp -a "$novatek" "$tmp_dir/lib/firmware/novatek_nt36672c_g7b_fw01.bin"
fi

mkdir -p "$(dirname "$output")"
tar -C "$tmp_dir" -czf "$output" lib

echo "Created: $output"
sha512sum "$output"
