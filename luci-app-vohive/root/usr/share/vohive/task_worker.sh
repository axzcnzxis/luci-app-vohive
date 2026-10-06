#!/bin/sh

set -eu

. /usr/share/vohive/task_lib.sh

id="${1:-}"
type="${2:-}"
shift 2 || true

BIN_DIR="/etc/vohive/bin"
BIN="$BIN_DIR/vohive"
VERSION_FILE="$BIN_DIR/version"
BACKUP_VERSION_FILE="$BIN_DIR/version.bak"
ARCH_FILE="$BIN_DIR/arch"
BACKUP_ARCH_FILE="$BIN_DIR/arch.bak"
TEMP_BACKUP="$DOWNLOAD_DIR/vohive.prev"
TEMP_CURRENT="$DOWNLOAD_DIR/vohive.current"
PLUGIN_REPO="${DEFAULT_PLUGIN_REPO}"

[ -n "$id" ] || exit 1
[ -n "$type" ] || exit 1

finish_ok() {
	task_finish "$id" "$type" 1 "$1"
	exit 0
}

fail() {
	task_fail "$id" "$type" "$1"
}

release_json_for_version() {
	local repo="$1"
	local version="$2"

	if [ "$version" = "latest" ] || [ "$version" = "stable" ]; then
		curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$repo/releases?per_page=20"
	else
		curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$repo/releases/tags/$version"
	fi
}

verify_release_asset() {
	local release_json="$1"
	local asset="$2"
	local file="$3"
	local repo="$4"
	local tag="$5"
	local digest sums

	digest="$(release_asset_field "$release_json" "$asset" digest 2>/dev/null || true)"
	if [ -n "$digest" ]; then
		if ! verify_sha256_digest "$file" "$digest"; then
			rm -f "$file"
			fail "SHA256 校验失败: $asset"
		fi
		return 0
	fi

	sums="$DOWNLOAD_DIR/sha256sums.txt"
	rm -f "$sums"
	task_download "$id" "$type" "https://github.com/$repo/releases/download/$tag/sha256sums.txt" "$sums" "sha256sums.txt" "$(task_asset_size "$release_json" "sha256sums.txt")"
	if ! verify_sha256sums_file "$file" "$sums" "$asset"; then
		rm -f "$file" "$sums"
		fail "SHA256 校验失败: $asset"
	fi
}

install_core() {
	local repo repo_input version selected_version core_arch core_arch_input asset_arch release_json asset url downloaded total was_running

	repo_input="${2:-}"
	if [ -n "$repo_input" ]; then
		repo="$(github_repo_slug "$repo_input")"
	else
		repo="$(github_repo_slug "$(uci_get release_repo "https://github.com/${DEFAULT_RELEASE_REPO}")")"
	fi
	validate_github_repo "$repo" || fail "Invalid GitHub repository: $repo"

	version="${1:-}"
	[ -n "$version" ] || version="$(uci_get version 'latest')"
	[ -n "$version" ] || version="latest"
	selected_version="$version"
	core_arch_input="${3:-}"
	if [ -n "$core_arch_input" ]; then
		core_arch="$core_arch_input"
	else
		core_arch="$(uci_get core_arch '')"
	fi
	asset_arch="$(resolve_asset_arch "$core_arch")" || fail "Unsupported configured architecture: $core_arch"

	uci set vohive.main.release_repo="https://github.com/$repo" 2>/dev/null || true
	uci set vohive.main.version="$selected_version" 2>/dev/null || true
	[ -z "$core_arch" ] || uci set vohive.main.core_arch="$core_arch" 2>/dev/null || true
	uci commit vohive 2>/dev/null || true

	task_log "$id" "查询 VoHive Release"
	task_write_status "$id" "$type" "running" "prepare" "正在查询 VoHive Release" "" 0 0 0 0
	release_json="$(release_json_for_version "$repo" "$version")" || fail "Failed to query release"
	if [ "$version" = "latest" ] || [ "$version" = "stable" ]; then
		version="$(find_core_release_tag "$release_json" "$asset_arch" 20)" || fail "未找到包含 linux_${asset_arch} 核心的 Release"
		release_json="$(release_json_for_version "$repo" "$version")" || fail "Failed to query release $version"
	else
		version="$(printf '%s' "$release_json" | jsonfilter -e '@.tag_name' 2>/dev/null || true)"
		[ -n "$version" ] || fail "Failed to parse release"
	fi

	asset="$(core_asset_name "$version" "$asset_arch")"
	release_asset_present "$release_json" "$asset" || fail "Release $version 中未找到 $asset"
	url="https://github.com/$repo/releases/download/$version/$asset"
	downloaded="$DOWNLOAD_DIR/$asset"
	total="$(task_asset_size "$release_json" "$asset")"

	mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"
	rm -f "$downloaded"
	task_download "$id" "$type" "$url" "$downloaded" "$asset" "$total"
	[ -s "$downloaded" ] || fail "Downloaded file is empty"

	task_log "$id" "校验核心文件"
	task_write_status "$id" "$type" "running" "verify" "正在校验核心文件" "$asset" "$(wc -c < "$downloaded" 2>/dev/null || echo 0)" "$total" 0 0
	verify_release_asset "$release_json" "$asset" "$downloaded" "$repo" "$version"
	chmod +x "$downloaded"
	if command -v file >/dev/null 2>&1; then
		file "$downloaded" | grep -Eq 'ELF|executable' || {
			rm -f "$downloaded"
			fail "Downloaded file is not an executable"
		}
	fi

	was_running=0
	/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1
	task_write_status "$id" "$type" "running" "install" "正在安装核心" "" 0 0 0 0
	[ "$was_running" = "0" ] || /etc/init.d/vohive stop || true

	if [ -x "$BIN" ]; then
		cp -f "$BIN" "$TEMP_BACKUP"
		if [ -s "$VERSION_FILE" ]; then
			cp -f "$VERSION_FILE" "$BACKUP_VERSION_FILE"
		else
			printf '已安装，版本未知\n' > "$BACKUP_VERSION_FILE"
		fi
		if [ -s "$ARCH_FILE" ]; then
			cp -f "$ARCH_FILE" "$BACKUP_ARCH_FILE"
		else
			printf 'unknown\n' > "$BACKUP_ARCH_FILE"
		fi
	fi

	cp -f "$downloaded" "$BIN"
	chmod 0755 "$BIN"
	printf '%s\n' "$version" > "$VERSION_FILE"
	printf '%s\n' "$asset_arch" > "$ARCH_FILE"

	if [ "$was_running" = "1" ]; then
		task_write_status "$id" "$type" "running" "restart" "正在重启 VoHive 服务" "" 0 0 0 0
		if ! /etc/init.d/vohive start >/tmp/vohive-start.log 2>&1; then
			if [ -f "$TEMP_BACKUP" ]; then
				cp -f "$TEMP_BACKUP" "$BIN"
				[ -s "$BACKUP_VERSION_FILE" ] && cp -f "$BACKUP_VERSION_FILE" "$VERSION_FILE"
				[ -s "$BACKUP_ARCH_FILE" ] && cp -f "$BACKUP_ARCH_FILE" "$ARCH_FILE"
				/etc/init.d/vohive start >/dev/null 2>&1 || true
			fi
			fail "Core installed but service failed to start; rolled back when possible"
		fi
	fi

	rm -f "$TEMP_BACKUP" "$downloaded" "$BIN_DIR/vohive.bak"
	finish_ok "已安装 VoHive 核心 $version"
}

rollback_core() {
	local repo rollback_version rollback_arch asset url downloaded total release_json was_running current_version current_arch

	repo="$(github_repo_slug "$(uci_get release_repo "https://github.com/${DEFAULT_RELEASE_REPO}")")"
	validate_github_repo "$repo" || fail "Invalid GitHub repository: $repo"

	rollback_version="$(cat "$BACKUP_VERSION_FILE" 2>/dev/null || true)"
	[ -n "$rollback_version" ] && [ "$rollback_version" != "已安装，版本未知" ] && [ "$rollback_version" != "版本未知" ] || fail "No rollback version recorded"

	rollback_arch="$(cat "$BACKUP_ARCH_FILE" 2>/dev/null || true)"
	if [ -z "$rollback_arch" ] || [ "$rollback_arch" = "unknown" ]; then
		rollback_arch="$(resolve_asset_arch "$(uci_get core_arch '')")" || fail "No rollback architecture recorded"
	fi

	task_log "$id" "查询回滚版本 $rollback_version"
	task_write_status "$id" "$type" "running" "prepare" "正在查询回滚版本" "" 0 0 0 0
	release_json="$(release_json_for_version "$repo" "$rollback_version")" || fail "Failed to query rollback release"

	asset="$(core_asset_name "$rollback_version" "$rollback_arch")"
	release_asset_present "$release_json" "$asset" || fail "Release $rollback_version 中未找到 $asset"
	url="https://github.com/$repo/releases/download/$rollback_version/$asset"
	downloaded="$DOWNLOAD_DIR/$asset"
	total="$(task_asset_size "$release_json" "$asset")"
	current_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
	current_arch="$(cat "$ARCH_FILE" 2>/dev/null || true)"

	mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"
	rm -f "$downloaded" "$TEMP_CURRENT"
	task_download "$id" "$type" "$url" "$downloaded" "$asset" "$total"
	[ -s "$downloaded" ] || fail "Downloaded rollback core is empty"

	task_log "$id" "校验回滚核心文件"
	task_write_status "$id" "$type" "running" "verify" "正在校验回滚核心文件" "$asset" "$(wc -c < "$downloaded" 2>/dev/null || echo 0)" "$total" 0 0
	verify_release_asset "$release_json" "$asset" "$downloaded" "$repo" "$rollback_version"
	chmod +x "$downloaded"
	if command -v file >/dev/null 2>&1; then
		file "$downloaded" | grep -Eq 'ELF|executable' || {
			rm -f "$downloaded"
			fail "Downloaded rollback core is not an executable"
		}
	fi

	was_running=0
	/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1
	task_write_status "$id" "$type" "running" "install" "正在回滚核心" "" 0 0 0 0
	[ "$was_running" = "0" ] || /etc/init.d/vohive stop || true

	[ ! -x "$BIN" ] || cp -f "$BIN" "$TEMP_CURRENT"
	cp -f "$downloaded" "$BIN"
	chmod 0755 "$BIN"
	printf '%s\n' "$rollback_version" > "$VERSION_FILE"
	printf '%s\n' "$rollback_arch" > "$ARCH_FILE"

	if [ "$was_running" = "1" ]; then
		task_write_status "$id" "$type" "running" "restart" "正在重启 VoHive 服务" "" 0 0 0 0
		if ! /etc/init.d/vohive start >/tmp/vohive-rollback-start.log 2>&1; then
			if [ -f "$TEMP_CURRENT" ]; then
				cp -f "$TEMP_CURRENT" "$BIN"
				[ -n "$current_version" ] && printf '%s\n' "$current_version" > "$VERSION_FILE"
				[ -n "$current_arch" ] && printf '%s\n' "$current_arch" > "$ARCH_FILE"
				/etc/init.d/vohive start >/dev/null 2>&1 || true
			fi
			fail "Rolled back core, but service failed to start; restored current core when possible"
		fi
	fi

	[ -n "$current_version" ] && printf '%s\n' "$current_version" > "$BACKUP_VERSION_FILE"
	[ -n "$current_arch" ] && printf '%s\n' "$current_arch" > "$BACKUP_ARCH_FILE"
	rm -f "$TEMP_CURRENT" "$downloaded" "$BIN_DIR/vohive.bak"
	finish_ok "已回滚到 $rollback_version"
}

update_plugin() {
	local json selection tag asset asset_version base package_file total manager installed_version installed_norm msg

	command -v curl >/dev/null 2>&1 || fail "缺少命令: curl"
	command -v jsonfilter >/dev/null 2>&1 || fail "缺少命令: jsonfilter"
	command -v sha256sum >/dev/null 2>&1 || fail "缺少命令: sha256sum"
	manager="$(package_manager)" || fail "未找到 opkg 或 apk"

	tmp_avail="$(df -kP /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
	[ "${tmp_avail:-0}" -ge 2048 ] || fail "/tmp 临时空间不足，至少需要 2 MB"

	task_log "$id" "查询 LuCI 插件最新版本"
	task_write_status "$id" "$type" "running" "prepare" "正在查询 LuCI 插件最新版本" "" 0 0 0 0
	json="$(curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$PLUGIN_REPO/releases?per_page=20")" || fail "查询插件最新版本失败"
	selection="$(find_plugin_release_asset "$json" "$manager" 20)" || fail "未找到适用于 $manager 的 LuCI 插件安装包"
	tag="${selection%% *}"
	asset="${selection#* }"
	asset_version="$(plugin_asset_version "$asset")" || fail "无法解析插件安装包版本: $asset"
	json="$(release_json_for_version "$PLUGIN_REPO" "$tag")" || fail "查询插件 Release $tag 失败"

	base="https://github.com/$PLUGIN_REPO/releases/download/$tag"
	package_file="$DOWNLOAD_DIR/$asset"
	total="$(task_asset_size "$json" "$asset")"

	rm -f "$package_file"
	task_download "$id" "$type" "$base/$asset" "$package_file" "$asset" "$total"
	[ -s "$package_file" ] || fail "插件安装包为空"

	task_log "$id" "校验插件安装包"
	task_write_status "$id" "$type" "running" "verify" "正在校验插件安装包" "$asset" "$(wc -c < "$package_file" 2>/dev/null || echo 0)" "$total" 0 0
	verify_release_asset "$json" "$asset" "$package_file" "$PLUGIN_REPO" "$tag"

	task_log "$id" "安装 LuCI 插件"
	task_write_status "$id" "$type" "running" "install" "正在安装 LuCI 插件" "" 0 0 0 0
	install_package_file "$package_file" >/tmp/vohive-plugin-install.log 2>&1 || {
		msg="$(tail -n 20 /tmp/vohive-plugin-install.log 2>/dev/null || true)"
		fail "安装 LuCI 插件失败: $msg"
	}

	installed_version="$(installed_plugin_version 2>/dev/null || true)"
	installed_norm="$(normalize_plugin_version "$installed_version" 2>/dev/null || true)"
	[ "$installed_norm" = "$asset_version" ] || {
		msg="$(tail -n 20 /tmp/vohive-plugin-install.log 2>/dev/null || true)"
		fail "安装后版本仍为 ${installed_version:-unknown}，期望 $asset_version。$msg"
	}

	printf '%s\n' "$asset_version" > /usr/share/vohive/plugin_version 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	finish_ok "LuCI 插件已更新到 $asset_version（Release $tag），页面即将刷新。"
}

convert_identity() {
	local port="${1:-}"
	local target="${2:-}"
	local result message

	[ -n "$port" ] || fail "缺少串口参数"
	[ -n "$target" ] || fail "缺少目标身份"

	task_write_status "$id" "$type" "running" "prepare" "准备转换 USB 身份" "" 0 0 0 0
	if result="$(VOHIVE_TASK_ID="$id" VOHIVE_TASK_TYPE="$type" /usr/share/vohive/device_tools.sh convert "$port" "$target" 2>&1)"; then
		message="$(printf '%s' "$result" | jsonfilter -e '@.message' 2>/dev/null || true)"
		finish_ok "${message:-设备身份转换已完成}"
	else
		message="$(printf '%s' "$result" | jsonfilter -e '@.message' 2>/dev/null || true)"
		fail "${message:-$result}"
	fi
}

switch_usbnet() {
	local port="${1:-}"
	local target="${2:-}"
	local result message

	[ -n "$port" ] || fail "缺少串口参数"
	[ -n "$target" ] || fail "缺少目标模式"

	task_write_status "$id" "$type" "running" "prepare" "准备切换 USB 网络模式" "" 0 0 0 0
	if result="$(VOHIVE_TASK_ID="$id" VOHIVE_TASK_TYPE="$type" /usr/share/vohive/device_tools.sh switch_usbnet "$port" "$target" 2>&1)"; then
		message="$(printf '%s' "$result" | jsonfilter -e '@.message' 2>/dev/null || true)"
		finish_ok "${message:-USB 网络模式切换已完成}"
	else
		message="$(printf '%s' "$result" | jsonfilter -e '@.message' 2>/dev/null || true)"
		fail "${message:-$result}"
	fi
}

probe_device() {
	local tmp="/tmp/vohive/device-probe.json.tmp"
	local cache="/tmp/vohive/device-probe.json"
	local result message

	task_write_status "$id" "$type" "running" "probe" "正在探测 USB 串口设备" "" 0 0 0 0
	if result="$(VOHIVE_TASK_ID="$id" VOHIVE_TASK_TYPE="$type" /usr/share/vohive/device_tools.sh probe 2>&1)"; then
		mkdir -p /tmp/vohive
		printf '%s\n' "$result" > "$tmp"
		mv -f "$tmp" "$cache"
		finish_ok "设备探测完成"
	else
		message="$(printf '%s' "$result" | jsonfilter -e '@.message' 2>/dev/null || true)"
		fail "${message:-$result}"
	fi
}

task_mkdirs
task_log "$id" "任务启动"

case "$type" in
	install_core) install_core "$@" ;;
	rollback_core) rollback_core ;;
	update_plugin) update_plugin ;;
	convert_identity) convert_identity "$@" ;;
	switch_usbnet) switch_usbnet "$@" ;;
	probe_device) probe_device ;;
	*) fail "不支持的任务类型: $type" ;;
esac
