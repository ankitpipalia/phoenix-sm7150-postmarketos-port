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

	# Portable in-place edit: BSD sed (macOS) requires `-i ''` while GNU sed
	# accepts `-i` alone. Do it via a temp file + mv instead, which is the
	# only form that works identically on both.
	local tmp
	tmp="$(mktemp)"
	if grep -q "^${symbol}=" "$config_file"; then
		sed "s/^${symbol}=.*/${symbol}=${value}/" "$config_file" > "$tmp"
		mv "$tmp" "$config_file"
	elif grep -q "^# ${symbol} is not set" "$config_file"; then
		sed "s/^# ${symbol} is not set/${symbol}=${value}/" "$config_file" > "$tmp"
		mv "$tmp" "$config_file"
	else
		rm -f "$tmp"
		echo "${symbol}=${value}" >> "$config_file"
	fi
}

update_source_block() {
	local file="$1"
	local list_file="$2"
	local tmp
	tmp="$(mktemp)"

	# Read patch-list from a file rather than -v so this works on BSD awk
	# (macOS default) which rejects newlines inside -v assignments.
	awk -v list_file="$list_file" '
	BEGIN {
		while ((getline line < list_file) > 0) {
			if (line != "")
				order[++count] = line;
		}
		close(list_file);
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
	local list_file="$2"
	local tmp
	tmp="$(mktemp)"

	awk -v list_file="$list_file" '
	BEGIN {
		while ((getline line < list_file) > 0) {
			if (line == "")
				continue;
			order[++count] = line;
			split(line, parts, /[ \t]+/);
			target[parts[length(parts)]] = 1;
		}
		close(list_file);
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
patch_paths=()
sum_lines=()

# Gather the local-truth patches first; validate at least one exists BEFORE
# touching the pmaports kernel directory. Otherwise a missing/empty source
# tree (wrong cwd, broken checkout) would `find -delete` the entire kernel
# patch dir with no replacements coming.
while IFS= read -r patch_path; do
	patch_name="$(basename "$patch_path")"
	patch_names+=("$patch_name")
	patch_paths+=("$patch_path")
	sum="$(sha512sum "$patch_path" | awk '{print $1}')"
	sum_lines+=("$sum  $patch_name")
done < <(LC_ALL=C find "$repo_root/kernel-patches" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)

if [[ "${#patch_names[@]}" -eq 0 ]]; then
	echo "No kernel patches found in $repo_root/kernel-patches" >&2
	exit 1
fi

# Now safely sync. We track which patches this script previously installed
# via a manifest in pmaports so we can remove patches that the source-of-truth
# no longer ships, without nuking unrelated upstream pmaports patches that
# might live in the same directory.
phoenix_manifest="$kernel_dir/.phoenix-managed-patches"

if [[ -f "$phoenix_manifest" ]]; then
	while IFS= read -r prev_patch; do
		[[ -z "$prev_patch" ]] && continue
		# Defensive: refuse to follow ../ or absolute paths in the manifest.
		case "$prev_patch" in
			*/*|.*) continue ;;
		esac
		rm -f "$kernel_dir/$prev_patch"
	done < "$phoenix_manifest"
fi

for patch_name in "${patch_names[@]}"; do
	rm -f "$kernel_dir/$patch_name"
done
for patch_path in "${patch_paths[@]}"; do
	cp -a "$patch_path" "$kernel_dir/"
done

# Refresh the manifest so the next sync run can clean up stale patches.
printf '%s\n' "${patch_names[@]}" > "$phoenix_manifest"

patch_list_file="$(mktemp)"
sum_lines_file="$(mktemp)"
trap 'rm -f "$patch_list_file" "$sum_lines_file"' EXIT

printf '%s\n' "${patch_names[@]}" > "$patch_list_file"

update_source_block "$kernel_apkbuild" "$patch_list_file"

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
printf '%s\n' "${ordered_sum_lines[@]}" > "$sum_lines_file"
update_sha512_entries "$kernel_apkbuild" "$sum_lines_file"

echo "Sync complete."
echo "Device package:   $device_testing_dir/device-xiaomi-phoenix"
echo "Firmware package: $device_testing_dir/firmware-xiaomi-phoenix"
echo "Kernel APKBUILD updated (source + checksums): $kernel_apkbuild"
echo "Kernel config updated:   $kernel_config"
