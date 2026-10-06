# luci-app-vohive

VoHive 的 OpenWrt / ImmortalWrt LuCI 管理插件。当前仓库是原项目失效后的维护 fork，Release、核心下载和插件更新均从本仓库获取。

## 当前状态

- 默认 Release 仓库：`https://github.com/axzcnzxis/luci-app-vohive`
- 当前核心版本：`v1.5.4`
- 当前插件版本：`0.1.21`
- 当前只发布 `x86_64` / `amd64` 核心包，因为 fork 中没有可用的 ARM 二进制文件。
- 核心和插件安装包下载后会校验 GitHub asset digest 或 Release 中的 `sha256sums.txt`。
- 插件更新同时支持 OpenWrt 24.10 的 `opkg` 和 OpenWrt 25.12 的 `apk`。

> `v0.1.19` 及更早的核心安装包在打包时被 OpenWrt 的 `rstrip` 步骤截断了 UPX
> 尾部，包内 `vohive` 二进制不可用，请使用 `v0.1.20` 或更新的 Release。

## 一键安装

适用于 OpenWrt / ImmortalWrt 24.10 和 25.12 的 `x86_64` 设备。脚本会自动识别
`opkg` 或 `apk`，下载最新 Release 中的插件和核心，校验 SHA256 后安装：

```sh
wget -qO- https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh
```

如果设备已安装 `curl`，也可以使用：

```sh
curl -fsSL https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh
```

指定版本安装：

```sh
wget -qO- https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh -s -- v0.1.21
```

脚本只会安装插件和 `vohive-core-amd64` 核心，不会修改现有 VoHive 配置。
安装完成后打开 LuCI 的 `服务 -> VoHive`。

## 包结构

- `luci-app-vohive`：LuCI 页面、UCI 配置、procd 服务、核心下载与回滚脚本，不包含 VoHive 二进制。
- `vohive-core-amd64`：预置 `vohive_v1.5.4_linux_amd64` 二进制和版本文件。

默认路径：

```text
/etc/config/vohive
/etc/vohive/bin/vohive
/etc/vohive/bin/version
/etc/vohive/bin/arch
/etc/vohive/config/config.yaml
/etc/vohive/data
/tmp/vohive/logs
/tmp/vohive/download
/tmp/vohive/tasks
```

## 功能

- 在 `服务 -> VoHive` 管理核心安装、更新和回滚。
- 从本仓库的 GitHub Release 列出可用版本，并显示当前版本与最新版本。
- 核心安装、核心回滚和 LuCI 插件更新使用任务弹窗显示下载进度、大小和速度。
- 启动、停止、重启 VoHive procd 服务。
- 通过 UCI 配置渲染 `/etc/vohive/config/config.yaml`。
- 显示核心状态、服务状态、端口监听提示和最近日志。
- 核心回滚只保留上一个版本和架构元数据，回滚时重新下载旧版本核心，不在闪存中保存第二份完整二进制。

## 手动安装

先下载本仓库对应 Release 中的安装包，然后执行：

OpenWrt 24.10 使用 IPK：

```sh
opkg update
opkg install ./luci-app-vohive_0.1.21-r1_all.ipk ./vohive-core-amd64_1.5.4-r1_x86_64.ipk
```

OpenWrt 25.12 使用 APK：

```sh
apk update
apk add --allow-untrusted ./luci-app-vohive-0.1.21-r1.apk ./vohive-core-amd64-1.5.4-r1.apk
```

也可以只安装 `luci-app-vohive`，进入 LuCI 页面后点击“安装/更新核心”。这种方式不会
预装本地核心包，后续由插件从 Release 下载核心。

当前架构对应关系：

```text
x86_64 / amd64 -> amd64
```

## 发布构建

手动触发 `Release Packages` workflow 时使用以下参数：

```text
plugin_version: v0.1.21
core_version: v1.5.4
core_repo: axzcnzxis/luci-app-vohive
```

推送新的 `v*` tag 也会触发构建：

```sh
git tag v0.1.21
git push origin v0.1.21
```

Release 产物：

```text
luci-app-vohive_0.1.21-r1_all.ipk
luci-app-vohive-0.1.21-r1.apk
vohive-core-amd64_1.5.4-r1_x86_64.ipk
vohive-core-amd64-1.5.4-r1.apk
sha256sums.txt
```

构建流程会先从 `core_repo` 的 `core_version` Release 下载 `vohive_v1.5.4_linux_amd64`，
优先使用 GitHub API 的 asset digest 校验（缺失时回退到 Release 的 `sha256sums.txt`，两者
都取不到会直接失败）。打包完成后还会从生成的 IPK / APK 中解出
`/etc/vohive/bin/vohive`，与下载的原始二进制做 SHA256 对比，任何不一致都会让构建失败。
`vohive-core` 关闭了 OpenWrt 的 `RSTRIP`，避免 UPX 二进制被截断。
核心包也标记为 `x86_64`，不会在 ARM 等不兼容目标上被包管理器误安装。

## 开发构建

把本仓库作为 OpenWrt SDK 的 package feed 使用，或复制到 SDK 的 `package/` 目录后执行：

```sh
make package/vohive/luci-app-vohive/compile V=s VOHIVE_PLUGIN_VERSION=0.1.21
make package/vohive/vohive-core/compile V=s VOHIVE_VERSION=v1.5.4
```

## ARM 说明

代码中保留了 ARM 架构处理路径，但 fork 中没有 `linux_arm64` 或 `linux_armv7` 核心文件，因此默认不构建 ARM 包。只有将对应二进制加入核心 Release 后，才应设置 `VOHIVE_ENABLE_ARM=1` 重新启用 ARM 包。
