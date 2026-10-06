# luci-app-vohive

VoHive 的 OpenWrt / ImmortalWrt LuCI 管理插件。当前仓库是原项目失效后的维护 fork，Release、核心下载和插件更新均从本仓库获取。

## 当前状态

- 默认 Release 仓库：`https://github.com/axzcnzxis/luci-app-vohive`
- 当前核心版本：`v1.5.4`
- 当前插件版本：`0.1.23`
- 当前只发布 `x86_64` / `amd64` 核心包，因为 fork 中没有可用的 ARM 二进制文件。
- 核心和插件安装包下载后会校验 GitHub asset digest 或 Release 中的 `sha256sums.txt`。
- 插件更新同时支持 OpenWrt 24.10 的 `opkg` 和 OpenWrt 25.12 的 `apk`。
- 串口驱动安装支持内核感知回退：当当前软件源没有与内核匹配的
  `kmod-usb-serial` / `kmod-usb-serial-wwan` / `kmod-usb-serial-option`
  时，会按已安装 `kernel` 软件包版本查找匹配的模块源，校验 IPK 的 SHA256
  后本地安装。该路径已按 `EC20EHC`（`2c7c:0125`）场景设计。
- `0.1.23` 起新增 QMI / MBIM 后端支持：可在“设备工具”中安装
  `kmod-usb-net-qmi-wwan` 或 `kmod-usb-net-cdc-mbim` 驱动链，并一键检测
  模块的 eSIM / APDU 能力与推荐传输方式。

> `v0.1.19` 及更早的核心安装包在打包时被 OpenWrt 的 `rstrip` 步骤截断了 UPX
> 尾部，包内 `vohive` 二进制不可用，请使用 `v0.1.20` 或更新的 Release。

## 一键安装

适用于 OpenWrt / ImmortalWrt 24.10 和 25.12 的 `x86_64` 设备。脚本会自动识别
`opkg` 或 `apk`，下载最新 Release 中的插件和核心，校验 SHA256 后安装：

```sh
wget -qO- https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh
```

如果同时需要安装或修复 EC20 等 USB 串口驱动，使用下面的一键命令：

```sh
wget -qO- https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh && /usr/share/vohive/device_tools.sh install_serial_drivers
```

如果还需要为 eSIM 安装 QMI 或 MBIM 后端驱动，继续执行：

```sh
/usr/share/vohive/device_tools.sh install_qmi_driver
/usr/share/vohive/device_tools.sh install_mbim_driver
```

如果设备已安装 `curl`，也可以使用：

```sh
curl -fsSL https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh
```

指定版本安装：

```sh
wget -qO- https://raw.githubusercontent.com/axzcnzxis/luci-app-vohive/main/install.sh | sh -s -- v0.1.23
```

脚本只会安装插件和 `vohive-core-amd64` 核心，不会修改现有 VoHive 配置。
安装完成后打开 LuCI 的 `服务 -> VoHive`。如果还没有 `/dev/ttyUSB*`，在设备依赖
区域点击“安装串口驱动”，或执行上面的组合命令。

## EC20 / 自定义内核串口驱动

OpenWrt 24.10 及以后，`kmod-*` 包通常不在 `core`、`base`、`packages`、`routing`
这四个常规源中，而是位于目标平台自己的 `kmods/<内核版本>/` 目录。自定义固件
（例如 CoolUC/Centerm 的 `6.18.2` 内核）还会使用与官方 24.10.5 不同的内核 ABI，
因此直接执行 `opkg install kmod-usb-serial kmod-usb-serial-option` 会出现：

```text
Unknown package 'kmod-usb-serial'.
Unknown package 'kmod-usb-serial-option'.
```

`0.1.23` 的“安装串口驱动”会按以下顺序处理：

1. 如果 `/lib/modules/$(uname -r)` 下已经存在 `usbserial.ko`、`usb_wwan.ko`、
   `option.ko`，直接加载，不联网安装。
2. 尝试使用设备当前的 `opkg` 或 `apk` 软件源安装三个模块包。
3. `opkg` 源中找不到匹配模块时，读取 `opkg status kernel` 的完整版本，并从
   默认模块源 `https://raw.githubusercontent.com/sbwml/openwrt_core2/x86_64/{kernel}`
   下载匹配内核的 IPK，校验 `Packages` 中的 SHA256 后本地安装。
4. 仍失败时输出实际内核版本、内核软件包版本和错误详情，并提示配置自定义模块源。

如果默认模块源不适用于你的固件，可以在 `/etc/config/vohive` 中覆盖：

```sh
uci set vohive.main.kmod_feed_base='https://example.com/openwrt-kmods/{kernel}'
uci commit vohive
```

`{kernel}` 会替换为 `kernel` 软件包的完整版本。例如本设备对应：

```text
6.18.2~8cd43842179db3bf4558923c83a3aa70-r1
```

安装完成后可用以下命令确认模块和串口：

```sh
lsmod | grep -E 'usbserial|usb_wwan|option'
ls /dev/ttyUSB*
```

## QMI / MBIM eSIM 传输

VoHive 核心支持 `at`、`qmi`、`mbim` 三种设备后端。`0.1.23` 起插件把这三种
后端所需的驱动安装和能力探测接入了 LuCI 设备工具，对应两条修复思路：

- 思路 1（QMI）：安装 `kmod-usb-net`、`kmod-usb-wdm`、`kmod-usb-net-qmi-wwan`。
  加载 `qmi_wwan` 后会生成 `/dev/cdc-wdm*` 控制口，核心可用
  `device_backend=qmi` + `control_device=/dev/cdc-wdm*` 接管模块。
- 思路 2（MBIM）：安装 `kmod-usb-net`、`kmod-usb-net-cdc-ether`、`kmod-usb-wdm`、
  `kmod-usb-net-cdc-ncm`、`kmod-usb-net-cdc-mbim`。加载 `cdc_mbim` 后会生成
  `/dev/cdc-wdm*` 控制口，核心可用 `device_backend=mbim` + `esim_transport=mbim`
  接管模块。

安装命令与串口驱动一致，支持内核感知回退：当前软件源没有与内核匹配的模块时，
会按 `kernel` 软件包版本从模块源下载 IPK 并校验 SHA256 后本地安装。

```sh
/usr/share/vohive/device_tools.sh install_qmi_driver
/usr/share/vohive/device_tools.sh install_mbim_driver
```

MBIM 后端还要求模块处于 MBIM 组态。Quectel 模块可用下面的命令切换（会重启模块）：

```sh
/usr/share/vohive/device_tools.sh switch_usbnet /dev/ttyUSB2 mbim
```

安装驱动后，用只读探测确认模块能力（不会写入模块）：

```sh
/usr/share/vohive/device_tools.sh probe_esim_capability /dev/ttyUSB2
```

关键输出字段：

- `at_apdu_supported`：AT 通道是否支持 `AT+CCHO` / `AT+CGLA` APDU。
- `qmi_device_present` / `mbim_device_present`：是否检测到对应的控制口。
- `recommended_transport`：推荐传输方式，取值为 `at`、`qmi`、`mbim` 或 `none`。

在 LuCI 的 `服务 -> VoHive -> 设备工具 -> 依赖状态` 中也有“安装 QMI 驱动”、
“安装 MBIM 驱动”和“检测 eSIM 能力”按钮，检测结果会直接显示推荐传输方式。

### 关于 EC20EHC 与 5ber 实体 eSIM

需要明确说明：**5ber 卡是一张可以写入多张 eSIM profile 的实体 SIM，不是真正的
eUICC（内置 eSIM 芯片）**。它的 profile 切换由卡内 STK / Applet 完成，对模块侧
表现为一张普通 SIM。

实测这台 `Quectel EC20EHC`（`2c7c:0125`）的固件不支持 AT APDU：
`AT+CCHO=?`、`AT+CGLA=?`、`AT+CCHC=?`、`AT+CSIM?` 均返回 `ERROR`。因此核心提示
“未检测到 eUICC / 此 SIM 卡可能不支持 eUICC 功能”是符合预期的，并非插件故障。

`0.1.23` 新增的 QMI / MBIM 驱动与探测让 VoHive 具备尝试 QMI / MBIM 传输的能力，
但能否真正读写这张 5ber 卡仍取决于模块固件是否在 QMI UIM / MBIM 通道上暴露
APDU 透传。**QMI / MBIM 支持不等于“5ber 一定可以管理”**：如果模块固件本身
不提供 APDU，任何后端都无法绕过。5ber 的 profile 增删请继续使用官方 App。

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
- 设备工具页支持串口 / QMI / MBIM 驱动的一键安装、eSIM 能力探测、
  USB 身份转换与 USB 网络模式切换。
- 核心回滚只保留上一个版本和架构元数据，回滚时重新下载旧版本核心，不在闪存中保存第二份完整二进制。

## 手动安装

`opkg install ./xxx.ipk` 和 `apk add ./xxx.apk` 只会读取本机已经存在的安装包。
如果直接执行下面的安装命令而没有先下载文件，就会提示
`No such file or directory`。请先进入 `/tmp` 并下载对应 Release 的安装包。

OpenWrt 24.10 使用 IPK：

```sh
cd /tmp
wget https://github.com/axzcnzxis/luci-app-vohive/releases/download/v0.1.23/luci-app-vohive_0.1.23-r1_all.ipk
wget https://github.com/axzcnzxis/luci-app-vohive/releases/download/v0.1.23/vohive-core-amd64_1.5.4-r1_x86_64.ipk
opkg update
opkg install ./luci-app-vohive_0.1.23-r1_all.ipk ./vohive-core-amd64_1.5.4-r1_x86_64.ipk
```

OpenWrt 25.12 使用 APK：

```sh
cd /tmp
wget https://github.com/axzcnzxis/luci-app-vohive/releases/download/v0.1.23/luci-app-vohive-0.1.23-r1.apk
wget https://github.com/axzcnzxis/luci-app-vohive/releases/download/v0.1.23/vohive-core-amd64-1.5.4-r1.apk
apk update
apk add --allow-untrusted ./luci-app-vohive-0.1.23-r1.apk ./vohive-core-amd64-1.5.4-r1.apk
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
plugin_version: v0.1.23
core_version: v1.5.4
core_repo: axzcnzxis/luci-app-vohive
```

推送新的 `v*` tag 也会触发构建：

```sh
git tag v0.1.23
git push origin v0.1.23
```

Release 产物：

```text
luci-app-vohive_0.1.23-r1_all.ipk
luci-app-vohive-0.1.23-r1.apk
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
make package/vohive/luci-app-vohive/compile V=s VOHIVE_PLUGIN_VERSION=0.1.23
make package/vohive/vohive-core/compile V=s VOHIVE_VERSION=v1.5.4
```

## ARM 说明

代码中保留了 ARM 架构处理路径，但 fork 中没有 `linux_arm64` 或 `linux_armv7` 核心文件，因此默认不构建 ARM 包。只有将对应二进制加入核心 Release 后，才应设置 `VOHIVE_ENABLE_ARM=1` 重新启用 ARM 包。
