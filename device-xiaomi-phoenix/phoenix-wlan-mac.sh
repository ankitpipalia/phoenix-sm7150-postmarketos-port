#!/bin/sh
set -eu

iface="${1:-wlan0}"
state_dir="/var/lib/phoenix"
state_file="$state_dir/${iface}-mac"

valid_mac() {
	echo "$1" | grep -Eiq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

derive_mac() {
	local src=""
	local hash=""
	local tail=""

	for f in /proc/device-tree/serial-number /sys/firmware/devicetree/base/serial-number /etc/machine-id; do
		[ -r "$f" ] || continue
		src="$(tr -d '\000\n\r ' < "$f" 2>/dev/null || true)"
		[ -n "$src" ] && break
	done

	[ -n "$src" ] || return 1
	hash="$(printf '%s' "$src" | sha256sum | awk '{print $1}')"
	tail="$(printf '%s' "$hash" | sed -E 's/^(.{2})(.{2})(.{2})(.{2})(.{2}).*/\1:\2:\3:\4:\5/')"
	echo "02:${tail}"
}

# Interface may appear slightly later during boot.
for _ in $(seq 1 30); do
	[ -e "/sys/class/net/$iface" ] && break
	sleep 1
done
[ -e "/sys/class/net/$iface" ] || exit 0

target_mac=""
if [ -r "$state_file" ]; then
	target_mac="$(tr -d '\n\r ' < "$state_file" | tr 'A-F' 'a-f' 2>/dev/null || true)"
fi

if ! valid_mac "$target_mac"; then
	target_mac="$(derive_mac || true)"
fi

valid_mac "$target_mac" || exit 0

mkdir -p "$state_dir"
printf '%s\n' "$target_mac" > "$state_file"
chmod 600 "$state_file"

current_mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null | tr 'A-F' 'a-f' || true)"
[ "$current_mac" = "$target_mac" ] && exit 0

ip link set dev "$iface" down || true
ip link set dev "$iface" address "$target_mac" || exit 0
ip link set dev "$iface" up || true
