#!/bin/sh
set -eu

iface="${1:-wlan0}"
state_dir="/var/lib/phoenix"
state_file="$state_dir/${iface}-mac"

valid_mac() {
	echo "$1" | grep -Eiq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

derive_mac() {
	src=""
	for f in /proc/device-tree/serial-number /sys/firmware/devicetree/base/serial-number /etc/machine-id; do
		[ -r "$f" ] || continue
		src="$(tr -d '\000\n\r ' < "$f" 2>/dev/null)" || src=""
		[ -n "$src" ] && break
	done

	[ -n "$src" ] || return 1
	hash="$(printf '%s' "$src" | sha256sum | awk '{print $1}')"
	tail="$(printf '%s' "$hash" | sed -E 's/^(.{2})(.{2})(.{2})(.{2})(.{2}).*/\1:\2:\3:\4:\5/')"
	echo "02:${tail}"
}

# Interface may appear slightly later during boot.
i=0
while [ "$i" -lt 30 ]; do
	[ -e "/sys/class/net/$iface" ] && break
	sleep 1
	i=$((i + 1))
done
[ -e "/sys/class/net/$iface" ] || exit 0

target_mac=""
if [ -r "$state_file" ]; then
	target_mac="$(tr -d '\n\r ' < "$state_file" 2>/dev/null | tr 'A-F' 'a-f')" || target_mac=""
fi

if ! valid_mac "$target_mac"; then
	target_mac="$(derive_mac)" || target_mac=""
fi

valid_mac "$target_mac" || exit 0

mkdir -p "$state_dir"
# Write atomically so two concurrent invocations can't truncate each other.
tmp_state="$(mktemp "$state_file.XXXXXX")" || exit 0
printf '%s\n' "$target_mac" > "$tmp_state"
chmod 600 "$tmp_state"
mv "$tmp_state" "$state_file"

current_mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null | tr 'A-F' 'a-f')" || current_mac=""
[ "$current_mac" = "$target_mac" ] && exit 0

ip link set dev "$iface" down || true
ip link set dev "$iface" address "$target_mac" || exit 0
ip link set dev "$iface" up || true
