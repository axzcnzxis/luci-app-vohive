#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

PLUGIN_REPO="${DEFAULT_PLUGIN_REPO}"
VERSION_FILE="/usr/share/vohive/plugin_version"
limit="${1:-5}"

case "$limit" in
	''|*[!0-9]*) limit=5 ;;
esac
[ "$limit" -gt 0 ] && [ "$limit" -le 20 ] || limit=5

manager="$(package_manager 2>/dev/null || true)"
current="$(installed_plugin_version 2>/dev/null || true)"
[ -n "$current" ] || current="$(cat "$VERSION_FILE" 2>/dev/null || true)"
[ -n "$current" ] || current="unknown"
current_norm="$(normalize_plugin_version "$current" 2>/dev/null || true)"

json="$(curl -fsSL --show-error --connect-timeout 8 --max-time 25 "https://api.github.com/repos/$PLUGIN_REPO/releases?per_page=$limit" 2>/tmp/vohive-plugin-releases.err)" || {
	msg="$(cat /tmp/vohive-plugin-releases.err 2>/dev/null || true)"
	printf '{"ok":false,"message":"%s","repo":"%s","current":"%s","latest":"","latest_release":"","has_update":false,"versions":[]}\n' \
		"$(json_escape "Failed to query plugin releases: $msg")" \
		"$(json_escape "$PLUGIN_REPO")" \
		"$(json_escape "$current")"
	exit 0
}

selection="$(find_plugin_release_asset "$json" "$manager" "$limit" 2>/dev/null || true)"
latest_tag=""
latest=""
if [ -n "$selection" ]; then
	latest_tag="${selection%% *}"
	latest="$(plugin_asset_version "${selection#* }" 2>/dev/null || true)"
fi
has_update=false
[ -n "$latest" ] && [ "$current_norm" != "$latest" ] && has_update=true

printf '{"ok":true,"repo":"%s","manager":"%s","current":"%s","latest":"%s","latest_release":"%s","has_update":%s,"versions":[' \
	"$(json_escape "$PLUGIN_REPO")" \
	"$(json_escape "$manager")" \
	"$(json_escape "$current")" \
	"$(json_escape "$latest")" \
	"$(json_escape "$latest_tag")" \
	"$has_update"
i=0
first=1
while [ "$i" -lt "$limit" ]; do
	tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
	[ -n "$tag" ] || break
	if [ -n "$manager" ] && release_has_plugin_asset "$json" "$i" "$manager"; then
		[ "$first" = 1 ] || printf ','
		printf '"%s"' "$(json_escape "$tag")"
		first=0
	fi
	i=$((i + 1))
done
printf ']}\n'
