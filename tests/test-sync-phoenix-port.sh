#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sync_script="$repo_root/scripts/sync-phoenix-port-into-pmaports.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/phoenix-sync-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

pmaports="$test_root/pmaports"
kernel_dir="$pmaports/device/community/linux-postmarketos-qcom-sm7150"
mkdir -p "$pmaports/.git" "$kernel_dir"

cat > "$kernel_dir/APKBUILD" <<'EOF'
pkgname=linux-postmarketos-qcom-sm7150
source="
	upstream.patch
	stale-phoenix.patch
	0001-dts-add-xiaomi-phoenix.patch
"
sha512sums="
cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  config-postmarketos-qcom-sm7150.aarch64
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  upstream.patch
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  stale-phoenix.patch
dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  0001-dts-add-xiaomi-phoenix.patch
"
EOF

cat > "$kernel_dir/config-postmarketos-qcom-sm7150.aarch64" <<'EOF'
# CONFIG_DRM_PANEL_G7B_37_02_0A_DSC is not set
# CONFIG_CHARGER_QCOM_SMB2 is not set
EOF
printf '%s\n' stale-phoenix.patch 0001-dts-add-xiaomi-phoenix.patch > \
	"$kernel_dir/.phoenix-managed-patches"
printf 'unrelated\n' > "$kernel_dir/upstream.patch"
printf 'stale\n' > "$kernel_dir/stale-phoenix.patch"

"$sync_script" "$pmaports" >/dev/null
first_result="$test_root/first-APKBUILD"
cp "$kernel_dir/APKBUILD" "$first_result"
"$sync_script" "$pmaports" >/dev/null
cmp -s "$first_result" "$kernel_dir/APKBUILD" || fail "second sync was not idempotent"

grep -q $'\tupstream.patch' "$kernel_dir/APKBUILD" || fail "unrelated source was removed"
grep -q '  upstream.patch' "$kernel_dir/APKBUILD" || {
	sed -n '/^sha512sums="/,/^"/p' "$kernel_dir/APKBUILD" >&2
	fail "unrelated checksum was removed"
}
if grep -q 'stale-phoenix.patch' "$kernel_dir/APKBUILD"; then
	fail "stale Phoenix entry was reinserted"
fi
if grep -q 'dummy' "$kernel_dir/APKBUILD"; then
	fail "dummy checksum was emitted"
fi

while IFS= read -r patch; do
	count=$(grep -c "${patch}$" "$kernel_dir/APKBUILD")
	[ "$count" -eq 2 ] || fail "$patch should occur once in source and once in checksums (got $count)"
done < "$kernel_dir/.phoenix-managed-patches"

awk '
/^sha512sums="/ { in_sha = 1; next }
in_sha && /^"/ { exit }
in_sha && NF {
	if ($1 !~ /^[0-9a-f]+$/ || length($1) != 128)
		exit 1
}
' "$kernel_dir/APKBUILD" || fail "invalid SHA-512 entry emitted"

[ ! -e "$kernel_dir/stale-phoenix.patch" ] || fail "stale managed patch file remains"
[ -e "$kernel_dir/upstream.patch" ] || fail "unrelated patch file was removed"

echo "sync helper tests: PASS"
