#!/bin/sh
# Verify a Windows 11 Arm64 ISO against the SHA-256 table Microsoft publishes on
# its official download page.  The table is fetched live, so the check follows
# whatever release Microsoft is currently serving rather than a stale copy.
#
#   scripts/verify-windows-arm64-iso.sh ~/Downloads/Win11_25H2_English_Arm64.iso [Language]
#
# Language defaults to "English 64-bit" (Microsoft's label for English (US) on
# this page; "English International 64-bit" is the other English build).
set -eu

iso=${1:?usage: $0 ISO [language-label]}
lang=${2:-"English 64-bit"}
page="https://www.microsoft.com/en-us/software-download/windows11arm64"
[ -r "$iso" ] || { echo "cannot read $iso" >&2; exit 2; }

# The page answers 403 to a bare user agent; a normal browser string reads the
# same public HTML a person sees.
ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
pinned="$(dirname "$0")/windows-arm64-iso-sha256.tsv"
source="live page"
table=$(curl -fsSL --max-time 60 -A "$ua" -H "Accept-Language: en-US" "$page" 2>/dev/null |
	python3 -c '
import html, re, sys
s = sys.stdin.read()
for lang, h in re.findall(r"<tr>\s*<td>([^<]+)</td>\s*<td>([0-9A-Fa-f]{64})</td>\s*</tr>", s):
    print(f"{html.unescape(lang).strip()}\t{h.lower()}")')
if [ -z "$table" ]; then
	[ -r "$pinned" ] || { echo "could not read the hash table from $page" >&2; exit 3; }
	table=$(grep -v '^#' "$pinned")
	source="pinned snapshot $(grep -o 'captured [0-9-]*' "$pinned") (live page unreachable)"
fi

expected=$(printf '%s\n' "$table" | awk -F '\t' -v l="$lang" '$1 == l {print $2}')
[ -n "$expected" ] || {
	echo "no published hash for \"$lang\"; available labels:" >&2
	printf '%s\n' "$table" | cut -f1 | sed 's/^/  /' >&2
	exit 3
}

echo "hashing $(basename "$iso") ($(du -h "$iso" | cut -f1)) ..."
actual=$(shasum -a 256 "$iso" | awk '{print $1}')
echo "published ($lang, $source): $expected"
echo "actual:            $actual"
if [ "$actual" = "$expected" ]; then
	echo "OK - matches Microsoft's published SHA-256"
else
	echo "MISMATCH - do not use this image" >&2
	exit 1
fi
