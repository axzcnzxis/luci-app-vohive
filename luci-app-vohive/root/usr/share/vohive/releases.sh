#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

repo="$(github_repo_slug "$(uci_get release_repo "https://github.com/${DEFAULT_RELEASE_REPO}")")"
limit="${1:-5}"

case "$limit" in
	''|*[!0-9]*) limit=5 ;;
esac
[ "$limit" -gt 0 ] && [ "$limit" -le 20 ] || limit=5
core_arch="$(resolve_asset_arch "$(uci_get core_arch '')" 2>/dev/null || true)"

validate_github_repo "$repo" || {
	printf '{"ok":false,"message":"%s","repo":"%s","latest":"","versions":[]}\n' "$(json_escape "Invalid GitHub repository: $repo")" "$(json_escape "$repo")"
	exit 0
}

json="$(curl -fsSL --show-error --connect-timeout 8 --max-time 25 "https://api.github.com/repos/$repo/releases?per_page=$limit" 2>/tmp/vohive-releases.err)" || {
	msg="$(cat /tmp/vohive-releases.err 2>/dev/null || true)"
	printf '{"ok":false,"message":"%s","repo":"%s","latest":"","versions":[]}\n' "$(json_escape "Failed to query releases: $msg")" "$(json_escape "$repo")"
	exit 0
}

latest=""
versions=""
i=0
while [ "$i" -lt "$limit" ]; do
	tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
	[ -n "$tag" ] || break
	if [ -n "$core_arch" ] && ! release_asset_present "$json" "$(core_asset_name "$tag" "$core_arch")"; then
		i=$((i + 1))
		continue
	fi
	if [ -z "$latest" ]; then
		latest="$tag"
	fi
	[ -z "$versions" ] || versions="${versions},"
	versions="${versions}\"$(json_escape "$tag")\""
	i=$((i + 1))
done
printf '{"ok":true,"repo":"%s","arch":"%s","latest":"%s","versions":[%s]}\n' \
	"$(json_escape "$repo")" \
	"$(json_escape "$core_arch")" \
	"$(json_escape "$latest")" \
	"$versions"
