#!/bin/sh

set -eu

REPO="${VOHIVE_REPO:-axzcnzxis/luci-app-vohive}"
REQUESTED_VERSION="${1:-${VOHIVE_VERSION:-latest}}"

log() {
	printf '%s\n' "$*"
}

fail() {
	printf 'VoHive install failed: %s\n' "$*" >&2
	exit 1
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

case "$REQUESTED_VERSION" in
	latest|stable)
		BASE_URL="https://github.com/${REPO}/releases/latest/download"
		;;
	v*)
		BASE_URL="https://github.com/${REPO}/releases/download/${REQUESTED_VERSION}"
		;;
	*)
		BASE_URL="https://github.com/${REPO}/releases/download/v${REQUESTED_VERSION}"
		;;
esac

arch="$(uname -m 2>/dev/null || true)"
case "$arch" in
	x86_64|amd64)
		;;
	*)
		fail "unsupported architecture ${arch:-unknown}; only x86_64/amd64 packages are published"
		;;
esac

if command_exists apk; then
	manager=apk
elif command_exists opkg; then
	manager=opkg
else
	fail "neither apk nor opkg was found"
fi

tmpdir="$(mktemp -d /tmp/vohive-install.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$tmpdir"' 0 1 2 15

download() {
	url="$1"
	output="$2"

	if command_exists curl; then
		curl -fL --connect-timeout 20 --retry 3 "$url" -o "$output"
	elif command_exists uclient-fetch; then
		uclient-fetch -q -O "$output" "$url"
	elif command_exists wget; then
		wget -q -O "$output" "$url"
	else
		fail "curl, uclient-fetch, and wget are all unavailable"
	fi
}

sums_file="$tmpdir/sha256sums.txt"
log "Downloading release checksums from ${BASE_URL}"
download "${BASE_URL}/sha256sums.txt" "$sums_file"

pick_asset() {
	pattern="$1"
	awk -v pattern="$pattern" '
		{
			name = $2
			sub(/^\*/, "", name)
			if (name ~ pattern) {
				print name
				exit
			}
		}
	' "$sums_file"
}

case "$manager" in
	apk)
		plugin_asset="$(pick_asset '^luci-app-vohive-[0-9].*\.apk$')"
		core_asset="$(pick_asset '^vohive-core-amd64-.*\.apk$')"
		;;
	opkg)
		plugin_asset="$(pick_asset '^luci-app-vohive_.*_all\.ipk$')"
		core_asset="$(pick_asset '^vohive-core-amd64_.*_x86_64\.ipk$')"
		;;
esac

[ -n "$plugin_asset" ] || fail "no compatible luci-app-vohive package was found"
[ -n "$core_asset" ] || fail "no compatible vohive-core-amd64 package was found"

plugin_file="$tmpdir/$plugin_asset"
core_file="$tmpdir/$core_asset"

log "Downloading ${plugin_asset}"
download "${BASE_URL}/${plugin_asset}" "$plugin_file"
log "Downloading ${core_asset}"
download "${BASE_URL}/${core_asset}" "$core_file"

verify_asset() {
	file="$1"
	asset="$2"
	expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$sums_file")"

	[ -n "$expected" ] || fail "checksum for ${asset} is missing"
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || fail "SHA256 mismatch for ${asset}"
}

verify_asset "$plugin_file" "$plugin_asset"
verify_asset "$core_file" "$core_asset"

log "Installing ${plugin_asset} and ${core_asset}"
case "$manager" in
	apk)
		apk update >/dev/null 2>&1 || true
		apk add --allow-untrusted "$plugin_file" "$core_file"
		;;
	opkg)
		opkg update >/dev/null 2>&1 || true
		opkg install "$plugin_file" "$core_file"
		;;
esac

log "Installation completed. Open LuCI -> Services -> VoHive."
