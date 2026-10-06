#!/bin/sh

DEFAULT_RELEASE_REPO="axzcnzxis/luci-app-vohive"
DEFAULT_PLUGIN_REPO="axzcnzxis/luci-app-vohive"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/\r//g; :a; N; $!ba; s/\n/\\n/g'
}

uci_get() {
	local key="$1"
	local default="$2"
	local value

	value="$(uci -q get "vohive.main.$key" 2>/dev/null || true)"
	[ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

github_repo_slug() {
	local repo="$1"

	repo="${repo#https://github.com/}"
	repo="${repo#http://github.com/}"
	repo="${repo#git@github.com:}"
	repo="${repo%/}"
	repo="${repo%.git}"

	printf '%s' "$repo"
}

validate_github_repo() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

core_asset_name() {
	printf 'vohive_%s_linux_%s' "$1" "$2"
}

release_asset_field() {
	local json="$1"
	local asset="$2"
	local field="$3"
	local i=0 name value

	while :; do
		name="$(printf '%s' "$json" | jsonfilter -e "@.assets[$i].name" 2>/dev/null || true)"
		[ -n "$name" ] || break
		if [ "$name" = "$asset" ]; then
			value="$(printf '%s' "$json" | jsonfilter -e "@.assets[$i].$field" 2>/dev/null || true)"
			printf '%s' "$value"
			return 0
		fi
		i=$((i + 1))
	done

	return 1
}

release_asset_present() {
	release_asset_field "$1" "$2" name >/dev/null 2>&1
}

find_core_release_tag() {
	local json="$1"
	local arch="$2"
	local limit="${3:-20}"
	local i=0 tag asset

	while [ "$i" -lt "$limit" ]; do
		tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
		[ -n "$tag" ] || break
		asset="$(core_asset_name "$tag" "$arch")"
		if release_asset_present "$json" "$asset"; then
			printf '%s' "$tag"
			return 0
		fi
		i=$((i + 1))
	done

	return 1
}

package_manager() {
	if command -v apk >/dev/null 2>&1; then
		printf 'apk'
		return 0
	fi
	if command -v opkg >/dev/null 2>&1; then
		printf 'opkg'
		return 0
	fi
	return 1
}

normalize_plugin_version() {
	local version="${1:-}"

	version="${version##*/}"
	version="${version#v}"
	version="${version#luci-app-vohive_}"
	version="${version#luci-app-vohive-}"
	version="${version%.apk}"
	version="${version%%_all.*}"
	version="${version%%_*}"
	version="${version%% *}"
	version="${version%-r*}"
	version="$(printf '%s' "$version" | sed -n 's/^\([0-9][0-9.]*\).*$/\1/p')"
	[ -n "$version" ] || return 1
	printf '%s' "$version"
}

plugin_asset_matches() {
	local name="$1"
	local manager="${2:-}"

	[ -n "$manager" ] || manager="$(package_manager)" || return 1
	case "$manager:$name" in
		opkg:luci-app-vohive_[0-9]*.ipk) return 0 ;;
		apk:luci-app-vohive-[0-9]*.apk) return 0 ;;
	esac
	return 1
}

plugin_asset_version() {
	plugin_asset_matches "$1" || return 1
	normalize_plugin_version "$1"
}

find_plugin_release_asset() {
	local json="$1"
	local manager="${2:-}"
	local limit="${3:-20}"
	local i=0 j=0 tag name

	[ -n "$manager" ] || manager="$(package_manager)" || return 1
	while [ "$i" -lt "$limit" ]; do
		tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
		[ -n "$tag" ] || break
		j=0
		while :; do
			name="$(printf '%s' "$json" | jsonfilter -e "@[$i].assets[$j].name" 2>/dev/null || true)"
			[ -n "$name" ] || break
			if plugin_asset_matches "$name" "$manager"; then
				printf '%s %s' "$tag" "$name"
				return 0
			fi
			j=$((j + 1))
		done
		i=$((i + 1))
	done

	return 1
}

release_has_plugin_asset() {
	local json="$1"
	local index="$2"
	local manager="${3:-}"
	local j=0 name

	[ -n "$manager" ] || manager="$(package_manager)" || return 1
	while :; do
		name="$(printf '%s' "$json" | jsonfilter -e "@[$index].assets[$j].name" 2>/dev/null || true)"
		[ -n "$name" ] || break
		plugin_asset_matches "$name" "$manager" && return 0
		j=$((j + 1))
	done

	return 1
}

installed_plugin_version() {
	local manager version

	manager="$(package_manager)" || return 1
	case "$manager" in
		opkg)
			version="$(opkg status luci-app-vohive 2>/dev/null | awk '/^Version:/ {print $2; exit}' || true)"
			;;
		apk)
			version="$(apk info -v luci-app-vohive 2>/dev/null | awk 'NR==1 {print $1}' || true)"
			[ -n "$version" ] || version="$(apk list --installed luci-app-vohive 2>/dev/null | awk 'NR==1 {print $1}' || true)"
			version="${version#luci-app-vohive-}"
			;;
	esac

	[ -n "$version" ] || return 1
	printf '%s' "$version"
}

install_package_file() {
	local manager

	manager="$(package_manager)" || return 1
	case "$manager" in
		opkg) opkg install "$1" ;;
		apk) apk add --allow-untrusted "$1" ;;
		*) return 1 ;;
	esac
}

verify_sha256_digest() {
	local file="$1"
	local digest="$2"
	local expected actual

	[ -n "$digest" ] || return 0
	case "$digest" in
		sha256:*) expected="${digest#sha256:}" ;;
		*) return 2 ;;
	esac
	case "$expected" in
		''|*[!0-9A-Fa-f]*) return 2 ;;
	esac
	command -v sha256sum >/dev/null 2>&1 || return 3

	actual="$(sha256sum "$file" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || return 1
	return 0
}

sha256sums_value() {
	local sums_file="$1"
	local asset="$2"
	local expected

	[ -s "$sums_file" ] || return 1
	expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f {print $1; exit}' "$sums_file" 2>/dev/null || true)"
	case "$expected" in
		''|*[!0-9A-Fa-f]*) return 1 ;;
	esac
	printf '%s' "$expected"
}

verify_sha256sums_file() {
	local file="$1"
	local sums_file="$2"
	local asset="$3"
	local expected actual

	command -v sha256sum >/dev/null 2>&1 || return 3
	expected="$(sha256sums_value "$sums_file" "$asset")" || return 2
	actual="$(sha256sum "$file" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || return 1
	return 0
}

resolve_asset_arch() {
	local configured="$1"
	local machine

	case "$configured" in
		'')
			machine="$(uname -m)"
			case "$machine" in
				aarch64|arm64) printf 'arm64' ;;
				x86_64|amd64) printf 'amd64' ;;
				armv7l|armv7) printf 'armv7' ;;
				*) return 1 ;;
			esac
			;;
		arm64|amd64|armv7)
			printf '%s' "$configured"
			;;
		*)
			return 1
			;;
	esac
}
