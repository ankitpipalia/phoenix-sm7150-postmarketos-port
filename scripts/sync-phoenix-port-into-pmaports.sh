#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pmaports_dir="${1:-$HOME/Documents/phoenix/pmaports}"

kernel_rel="device/community/linux-postmarketos-qcom-sm7150"
kernel_dir="$pmaports_dir/$kernel_rel"
kernel_apkbuild="$kernel_dir/APKBUILD"
device_testing_dir="$pmaports_dir/device/testing"

require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Missing required command: $cmd" >&2
		exit 1
	fi
}

ensure_kernel_config_symbol() {
	local config_file="$1"
	local symbol="$2"
	local value="$3"

	if [[ ! -f "$config_file" ]]; then
		echo "Kernel config not found: $config_file" >&2
		exit 1
	fi

	if grep -q "^${symbol}=" "$config_file"; then
		sed -i "s/^${symbol}=.*/${symbol}=${value}/" "$config_file"
	elif grep -q "^# ${symbol} is not set" "$config_file"; then
		sed -i "s/^# ${symbol} is not set/${symbol}=${value}/" "$config_file"
	else
		echo "${symbol}=${value}" >> "$config_file"
	fi
}

update_source_block() {
	local file="$1"
	local patch_list="$2"
	local tmp
	tmp="$(mktemp)"

	awk -v patch_list="$patch_list" '
	BEGIN {
		n = split(patch_list, p, "\n");
		for (i = 1; i <= n; i++) {
			if (p[i] != "")
				order[++count] = p[i];
		}
	}
	$0 ~ /^source="/ { in_source = 1 }
	in_source {
		line = $0;
		gsub(/^[ \t]+|[ \t]+$/, "", line);
		gsub(/^"/, "", line);
		gsub(/"$/, "", line);
		if (line ~ /\.patch$/)
			next;
	}
	in_source && $0 == "\"" {
		for (i = 1; i <= count; i++) {
			print "\t" order[i];
		}
		print;
		in_source = 0;
		next;
	}
	{ print }
	' "$file" > "$tmp"

	mv "$tmp" "$file"
}

update_sha512_entries() {
	local file="$1"
	local sum_lines="$2"
	local tmp
	tmp="$(mktemp)"

	awk -v sum_lines="$sum_lines" '
	BEGIN {
		m = split(sum_lines, s, "\n");
		for (i = 1; i <= m; i++) {
			if (s[i] == "")
				continue;
			order[++count] = s[i];
			split(s[i], parts, /[ \t]+/);
			target[parts[length(parts)]] = 1;
		}
	}
	$0 ~ /^sha512sums="/ { in_sha = 1 }
	in_sha && $0 == "\"" {
		for (i = 1; i <= count; i++) {
			print order[i];
		}
		print;
		in_sha = 0;
		next;
	}
	in_sha {
		line = $0;
		gsub(/^[ \t]+/, "", line);
		if (line == "") {
			print;
			next;
		}
		split(line, parts, /[ \t]+/);
		file_name = parts[length(parts)];
		if (target[file_name])
			next;
		if (file_name ~ /\.patch$/)
			next;
	}
	{ print }
	' "$file" > "$tmp"

	mv "$tmp" "$file"
}

require_cmd git
require_cmd awk
require_cmd sha512sum
require_cmd mktemp

if [[ -d "$pmaports_dir/.git" ]]; then
	echo "Using existing pmaports: $pmaports_dir"
else
	echo "Cloning pmaports into: $pmaports_dir"
	git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$pmaports_dir"
fi

if [[ ! -d "$kernel_dir" || ! -f "$kernel_apkbuild" ]]; then
	echo "Expected kernel package not found: $kernel_dir" >&2
	exit 1
fi

mkdir -p "$device_testing_dir"
rm -rf "$device_testing_dir/device-xiaomi-phoenix" "$device_testing_dir/firmware-xiaomi-phoenix"
cp -a "$repo_root/device-xiaomi-phoenix" "$device_testing_dir/"
cp -a "$repo_root/firmware-xiaomi-phoenix" "$device_testing_dir/"

patch_names=()
sum_lines=()

# Remove previously synced local kernel patch files so deleted patches in
# source-of-truth don't linger in the pmaports package directory.
find "$kernel_dir" -maxdepth 1 -type f -name '*.patch' -delete

while IFS= read -r patch_path; do
	patch_name="$(basename "$patch_path")"
	patch_names+=("$patch_name")
	cp -a "$patch_path" "$kernel_dir/"
	sum="$(sha512sum "$patch_path" | awk "{print \$1}")"
	sum_lines+=("$sum  $patch_name")
done < <(find "$repo_root/kernel-patches" -maxdepth 1 -type f -name '*.patch' | sort)

if [[ "${#patch_names[@]}" -eq 0 ]]; then
	echo "No kernel patches found in $repo_root/kernel-patches" >&2
	exit 1
fi

patch_list_text="$(printf '%s\n' "${patch_names[@]}")"

update_source_block "$kernel_apkbuild" "$patch_list_text"

# The phoenix panel driver is introduced by 0001/0003 and must be enabled
# explicitly in the package kernel config to avoid oldconfig prompts/defaults.
kernel_config="$kernel_dir/config-postmarketos-qcom-sm7150.aarch64"
ensure_kernel_config_symbol "$kernel_config" "CONFIG_DRM_PANEL_G7B_37_02_0A_DSC" "m"

# PM6150 charger driver (qcom_smbx) needed for battery charging support.
ensure_kernel_config_symbol "$kernel_config" "CONFIG_CHARGER_QCOM_SMB2" "m"

# Keep checksums aligned with local patch/config mutations to avoid abuild
# verification failures during pmbootstrap build.
config_sum="$(sha512sum "$kernel_config" | awk '{print $1}')"
ordered_sum_lines=("$config_sum  $(basename "$kernel_config")" "${sum_lines[@]}")
sum_lines_text="$(printf '%s\n' "${ordered_sum_lines[@]}")"
update_sha512_entries "$kernel_apkbuild" "$sum_lines_text"

echo "Sync complete."
echo "Device package:   $device_testing_dir/device-xiaomi-phoenix"
echo "Firmware package: $device_testing_dir/firmware-xiaomi-phoenix"
echo "Kernel APKBUILD updated (source + checksums): $kernel_apkbuild"
echo "Kernel config updated:   $kernel_config"
