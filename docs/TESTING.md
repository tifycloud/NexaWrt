# NexaWrt：Xiaomi AX9000 initramfs 测试流程

本流程只适用于 **NexaWrt 当前支持的 Xiaomi AX9000 single-large-UBI v1 布局**，
并且只覆盖 **initramfs RAM 启动测试**。它不包含安装、sysupgrade、UBI 重建或任何
闪存写入步骤；其他设备或布局必须另行制定测试流程，本文不构成未来支持承诺。
默认测试对象是 `official` flavor；`nss` 只是由 `manifests/nss.lock` 锁定到
`qosmio/openwrt-ipq` `25.12-nss` / `d6848fa2...` 的实验性可选对照组。**当前尚未完成任何 flavor 的真机 RAM 启动批准；
本文是验收流程，不是执行授权。**

源获取策略的本地回归测试使用完全本地的 Git fixture，不依赖外网：

```sh
./tests/test_source_fetch_policy.sh
./tests/test_feed_reuse_policy.sh
```

verified-dist 与最终真机批准的本地策略回归使用最小但完整的真实 schema fixture，不运行完整构建：

```sh
./tests/test_reproducibility_policy.sh
./tests/test_create_hardware_session.sh
./tests/test_hardware_gate.sh
```

这些测试要求只接受 compare 生成的 schema-4 verified dist，并覆盖缺失/伪造 reproducibility、错误
source/feed lock 或 reviewed patch digest、复制同一构建冒充双构建、错误 a/b/run build identity、缺失/
额外/篡改完整构建输入、无效 `EVIDENCE.sha256`、替换 input receipt、批准未绑定 receipt、以及 firmware
SHA-256/size 不一致等
fail-closed 负例。`INPUTS.sha256` 必须绑定 Makefile、构建/验证/证据/比较脚本、共享 Git 环境净化器、
内核身份检查器、flavor config、overlay、锁文件、受审 patch，以及 NSS `THIRD_PARTY_NOTICES.md`，而不只是
manifests/patches 子集。旧式“只有 firmware 字符串和 `flavor=nss`”fixture 必须失败。

`tests/test_git_environment_policy.sh` 还向共享净化器注入恶意 `GIT_DIR`、worktree/index/object store、
namespace、global/system/config-count、exec path 与 template 变量，要求所有重定向均被清除，并验证全部 Git
入口在首次仓库操作前只调用一次净化器。

这些测试证明：source origin 的 raw `remote.origin.url` 必须恰好一个且精确等于当前 flavor 的
canonical URL，`remote.origin.pushurl` 必须完全不存在；同时本地必须存在完整、对象类型为 commit 的
exact `SOURCE_COMMIT` checkout closure，`scripts/prepare.sh` 才跳过网络 fetch。之后仍强制
checkout/reset 到 exact commit、清理未跟踪文件、应用 patch 并执行既有 validation。错误/额外 fetch
URL、单个或多个 pushurl 会在 fetch 前拒绝；缺失 commit 或同名非 commit 对象不会被当作缓存命中，
仍进入原有 exact-commit 三次 fetch 重试。

完整 feed 安装状态也可离线复用，但必须同时满足所有 lock 的 exact HEAD、上述 raw canonical origin
策略、无 lazy-fetch/replace 的完整 tree/blob closure、无 sparse/index 技巧、无 staged/untracked/ignored
内容，以及 feed 顶层集合和 `package/feeds` 符号链接 exact set/containment 校验；NSS packages checkout
只允许精确 reviewed patch。任一条件失败（包括错误/额外 fetch URL、单个/多个 pushurl、缺 blob、dirty、
额外 feed 或越界 package link）都删除 feed 安装状态并进入既有逐 feed exact fetch/shallow fallback，
不会放宽 feed exact pin。复用路径仍重新复制 seed、运行 `make defconfig`、移除生成的 feed metadata，
并执行全部最终 feed/source validation。

Kconfig product version 的真实保留行为使用 disposable `/tmp` checkout 验证，不触碰项目构建目录：

```sh
./tests/test_openwrt_defconfig_version.sh nss
```

该测试获取锁定 source，在 `/tmp` fixture 中复制对应 seed，构建该 source 的真实 OpenWrt Kconfig
`conf`，并以 OpenWrt 顶层同样的 `--defconfig=.config` recipe 运行 `make defconfig`；它要求
`CONFIG_IMAGEOPT=y`、`CONFIG_VERSIONOPT=y` 和 `CONFIG_VERSION_CODE="nexawrt-r0-d6848fa2"` 仍精确存在。测试需要网络和
主机编译工具，因此不属于默认离线 static suite；也可传入仓库外的 disposable locked source。

## 0. 停止条件

开始或执行过程中出现以下任一情况，立即停止并保留日志：

- 设备不是 Xiaomi AX9000；
- `/proc/mtd` 中 `rootfs` 大小不是 `0x0e800000`；
- UBI volume 不是 0=`kernel`、1=`rootfs`、2=`rootfs_data`；
- NexaWrt RAM-test 的 `/proc/cmdline` 没有且仅有一个 `root=/dev/ram0`；
- NexaWrt RAM-test 的 `/proc/cmdline` 出现 `ubi.mtd=` 或 `/dev/ubiblock`；
- `/sys/class/ubi` 下出现自动附加的持久 UBI 设备；
- U-Boot 的 MTD/UBI 可见范围尚未记录，或与 Linux 的 `rootfs` 边界不一致；
- 无法确认镜像 flavor，或 artifact、清单、配置与所声明 flavor 不一致；
- `official` 镜像不是基于 OpenWrt `v25.12.5` / `f0a60eee...`，或意外包含第三方 NSS/ECM/NSS firmware；
- `nss` 镜像不是基于 `manifests/nss.lock` 锁定的 `qosmio/openwrt-ipq` `25.12-nss` /
  `d6848fa2ea00193b5b7d3973e3990da7f608027c`，或混入 `official` 的构建缓存/overlay；
- NSS 测试中 `network.globals.packet_steering`、`firewall.@defaults[0].flow_offloading` 或
  `firewall.@defaults[0].flow_offloading_hw` 不是 `0`；
- 尚未完成关键 MTD 备份和 SHA-256 校验；
- UART 输入不可靠、无法中断 U-Boot 或无法恢复当前启动；
- 任何步骤要求擦除、写入、格式化或调整 MTD/UBI。

当前没有发现可依赖的既有备份。完成备份并验证 UART/U-Boot/initramfs 之前，禁止写闪存。
即使 RAM 测试通过，当前阶段仍禁止生成、发布或使用任何持久化刷写产物。生产系统中的
`root=/dev/ubiblock0_1` 仅作为小米原厂/当前布局基线记录，不得用于 NexaWrt RAM-test。

## 1. 当前生产系统基线

在当前生产系统运行只读备份：

```sh
./scripts/backup-router.sh
```

检查输出目录：

```sh
cat proc-mtd.txt
cat fw_printenv.txt
sha256sum -c SHA256SUMS
```

macOS 可使用：

```sh
shasum -a 256 -c SHA256SUMS
```

确认以下关键分区均有 `.bin` 文件，且脚本报告的实际字节数与 `/proc/mtd` 中声明的大小
完全相同：

- `appsblenv`
- `appsbl`
- `appsbl_1`
- `art`
- `bdata`
- `bootconfig`
- `bootconfig1`
- `rootfs`

额外记录：

- 路由器型号、序列号标签（不要公开上传）；
- 电源规格；
- 当前固件版本；
- LAN/WAN/MAC 对应关系；
- 当前生产固件冷启动 UART 全日志；
- 小米原厂/当前生产系统的完整内核命令行，其中 `root=/dev/ubiblock0_1` 只作为基线；
- U-Boot 加载地址、网络参数和可用命令。

## 2. UART、会话与 U-Boot 预检

1. 使用 3.3 V UART，仅连接 TX/RX/GND，不接 5 V；冷启动并保存连续完整日志。
2. 中断 U-Boot，只执行已确认无副作用的 `help`、`printenv` 和内存信息命令；保存生产
   `printenv`、`mtdparts`、`bootcmd` 及相关启动变量。
3. 至少两次验证能中断并继续当前生产启动，且前后完整 `fw_printenv` 不变。
4. 为每次候选冷启动创建独立证据目录和随机会话：

```sh
EVIDENCE="$PWD/hardware-evidence/ax9000-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$EVIDENCE"
./scripts/create-hardware-session.sh "$EVIDENCE" <verified-dist>
```

`SESSION.txt` 必须只有 `session_id=<64 位小写 hex>` 一行。创建脚本还必须生成严格十字段
`CANDIDATE.txt`，绑定 flavor、真实 ITB filename/SHA-256/size、verified-dist `SHA256SUMS`、
`REPRODUCIBILITY.json`、`BUILD-MANIFEST.txt` 三个文件摘要，以及 repository-input 和双构建 comparison
receipt 摘要。所有 production/runtime collector、压力测试和最终签名都复用这一个目录与 session；最终
验证会重新验证 verified dist 并要求 candidate metadata 逐字节一致，不得手工复用旧会话或改选目录。

5. TFTP 已完成并得到 `${filesize}` 后，使用脚本输出的**临时** U-Boot 命令：向当前 bootargs
   追加且仅追加一个 `nexawrt.session=<session>`，对 `${loadaddr}` 到 `${filesize}` 的实际内存
   计算 SHA-256，保存 `${filesize}` 的十六进制值，并执行：

```text
printenv nexawrt_image_sha256 nexawrt_image_size_hex nexawrt_session_id ethaddr
```

6. `uart-cold-boot.log` 必须各恰好一次记录 `nexawrt_image_sha256=`、
   `nexawrt_image_size_hex=`、`nexawrt_session_id=`、`ethaddr=`；不能只抄开发机预期值。
7. 若 U-Boot 提供 UBI 信息/读取命令，先用 `help` 核对语义，只读记录扫描范围；禁止
   create/remove/write/erase。
8. **绝不执行 `saveenv`，不修改或保存 bootcmd/bootargs/启动槽，不运行任何 NAND/MTD/UBI
   写命令。** 若命令语义、加载地址或恢复路径不确定，立即停止。

通过标准：每次均能可靠观察、中断、测量实际 RAM 镜像并恢复当前启动；生产环境变量没有持久变化。

## 3. initramfs 镜像门检

加载前记录镜像的：

- 两个独立干净构建的可复现性比较结果。候选必须是
  `scripts/compare-reproducible-builds.sh` 生成且通过 `--verify-verified-dist` 的目录；严格
  `REPRODUCIBILITY.json` 必须为 schema 4、`reproducible=true`，绑定恰好两个 input checksum/evidence
  receipts、comparison receipt、repository-input receipt，以及与真实 ITB 一致的 flavor/filename/SHA/size；
  左右 checksum/evidence receipt 摘要必须分别不同，`BUILD-IDENTITY.txt` 必须分别绑定 a/b 和同一 run，且
  `EVIDENCE.sha256` 必须校验精确 evidence payload 集并绑定对应 build identity。正式真机候选还必须让两个
  input build 各自绑定不同的 `github-artifact:<id>:bundle-sha256:<digest>` producer identity，并嵌入由
  GitHub 签名、绑定 artifact ID/name、run、replica 与 receipt digest 的 canonical producer descriptor；
  verifier 必须由显式绝对路径和预期 SHA-256 双重固定，不能从 `PATH` 注入。`local-unattested:a|b` 仅供开发预检，最终硬件 gate 必须拒绝。
  `BUILD-MANIFEST.txt` 中 source repository/commit 和每个 flavor 预期 feed repository/commit/patch digest
  必须与 `manifests/*.lock`、`EVIDENCE/SOURCE-STATE.txt`、`EVIDENCE/INPUTS.sha256` 及当前 reviewed patch
  完全一致；`INPUTS.sha256` 还必须精确绑定 Makefile、构建/验证/证据脚本、flavor config 与 overlay 的完整
  非符号链接文件集；两个 input 的项目树必须为 `clean`，且其 `project_commit` 必须精确等于验证器仓库 `HEAD`；
  两个 seed 与解析后的 `.config` 必须固定
  `CONFIG_KERNEL_BUILD_USER="nexawrt"`、`CONFIG_KERNEL_BUILD_DOMAIN="builder"`、`CONFIG_IMAGEOPT=y`、
  `CONFIG_VERSIONOPT=y`。
  official 的
  `CONFIG_VERSION_CODE="nexawrt-r0-f0a60eee"` 必须来自 `manifests/upstream.lock` 的
  `OPENWRT_COMMIT` 前 8 位；NSS 的 `CONFIG_VERSION_CODE="nexawrt-r0-d6848fa2"` 必须来自
  `manifests/nss.lock` 的 `NSS_OPENWRT_COMMIT` 前 8 位。小写产品前缀保证该显式值不会等于
  OpenWrt 动态 `git %h` default；`CONFIG_IMAGEOPT=y` 使版本选项菜单可见，`CONFIG_VERSIONOPT=y`
  再使该字符串符号可见，三者共同确保经过 `make defconfig` 后仍保留。禁止使用 7 位动态缩写，
  也禁止跨 flavor 复用 revision。构建脚本保留匹配的 `KBUILD_BUILD_USER=nexawrt`、
  `KBUILD_BUILD_HOST=builder` 与 `KBUILD_BUILD_VERSION=0` 作为防御，但 OpenWrt
  `include/kernel.mk` 下 user/domain 的权威来源是 resolved Kconfig；
- 构建证据日志凭据扫描通过。扫描对 GitHub token 前缀大小写敏感：真实小写前缀必须拒绝，
  大写 `GHS_` 编译测试向量不应误报，私钥标记仍必须拒绝；

- 完整文件名和字节大小；
- SHA-256；
- flavor（`official` 或 `nss`）及对应 artifact 名；
- `official` 的 OpenWrt tag `v25.12.5` 与提交前缀 `f0a60eee...`，或 `nss` 的
  `qosmio/openwrt-ipq` `25.12-nss` 固定 commit `d6848fa2ea00193b5b7d3973e3990da7f608027c`；
- NexaWrt 当前 AX9000 补丁、配置、feeds 和 overlay 清单；
- `official` 明确不含第三方 NSS 加速栈/ECM/NSS firmware；`nss` 明确列出 NSS/ECM
  包、firmware 来源及其许可证检查结果；
- 构建日志和配置；
- `official` 与 `nss` 配置都启用已裁剪的 `uboot-envtools`，但仍禁用 `mtd`、`ubi-utils`；
- AX9000 profile 的 `DEVICE_PACKAGES` 恰好为 `-ubi-utils -mtd`，不得包含 `-uboot-envtools`；
  OpenWrt `merge_packages` 的显式负包会覆盖 seed config，不能只凭
  `CONFIG_PACKAGE_uboot-envtools=y` 判断最终镜像包含读工具；
- `patches/003-uboot-envtools-read-only.patch` 保留 `fw_printenv`、`fw_printsys` 和 target-specific
  `/etc/uci-defaults/30_uboot-envtools`，只删除 `fw_setenv`、`fw_setsys`、`fw_loadenv` 与
  `/etc/board.d/05_fw_defaults`；`30_uboot-envtools` 只允许在 initramfs/tmpfs 生成 AX9000
  `appsblenv` 的读取定位配置，不得调用任何 set/write、MTD 或 UBI 写工具；
- 候选命令行明确使用 `root=/dev/ram0`，且不含 `ubi.mtd=` 或 `/dev/ubiblock`；
- 启动流程审查证明不会自动附加、挂载或写入持久 UBI；
- 针对本次真机 RAM 启动的明确批准记录。

只接受 initramfs RAM 启动产物。不要把官方 factory/sysupgrade 镜像或其他布局镜像当作
NexaWrt 测试镜像，也不要执行任何“先刷进去再试”的步骤。

## 4. U-Boot RAM 加载

不同 U-Boot 版本的地址和命令可能不同，必须以现场 `help`、`printenv`、内存布局及恢复演练为准，
不能盲目复制固定地址。

安全顺序：

1. 只把 verified initramfs 下载到已确认安全的 RAM 地址；
2. 使用 U-Boot 对实际已加载内存计算 SHA-256，并保留 `${filesize}` 的十六进制原值；
3. 临时追加 `nexawrt.session=<SESSION.txt>`，打印 SHA、size、session、`ethaddr` 四项；
4. 确认 UART 中每项只出现一次且与本次 verified dist/session/生产设备一致；
5. 只执行与镜像格式匹配的 RAM 启动命令；
6. 不执行 `saveenv`、`fw_setenv`、`nand`、`mtd`、`ubi` 写操作，不持久保存临时 bootargs。

若任一实际测量值不一致、字段重复、加载地址或恢复路径有疑问，停止，不启动、不猜测。

## 5. initramfs 启动后只读验证

进入 initramfs 后先确认根文件系统确实位于 RAM/临时 root，并确认持久 UBI 没有被自动
附加。测试不依赖 `ubinfo`；以 `/proc/cmdline` 和 `/sys/class/ubi` 为准。随后只做只读检查：

```sh
set -eu
cmdline="$(cat /proc/cmdline)"
printf '%s\n' "$cmdline"
root_count="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -cx 'root=/dev/ram0')"
[ "$root_count" -eq 1 ]
! printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -Eq '^(ubi\.mtd=|root=/dev/ubiblock)'
cat /proc/mtd
# 只测试以写模式打开，不发送任何数据或擦除 ioctl。所有 MTD 分区都必须被内核拒绝写打开。
for dev in /dev/mtd[0-9]*; do
    [ -e "$dev" ] || continue
    # 仅请求以写模式打开文件描述符，不执行 write(2)、擦除或 ioctl。
    if (exec 9>"$dev") 2>/tmp/mtd-write-probe.err; then
        echo "UNEXPECTED WRITABLE MTD: $dev" >&2
        exit 1
    fi
done
mount
ls -la /sys/class/ubi 2>/dev/null || true
for path in /sys/class/ubi/ubi[0-9]*; do
    [ ! -e "$path" ] || {
        echo "UNEXPECTED PERSISTENT UBI: $path" >&2
        exit 1
    }
done
ip link
ip addr
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null
command -v fw_printenv fw_printsys
test -f /etc/uci-defaults/30_uboot-envtools
test ! -e /etc/board.d/05_fw_defaults
for write_tool in fw_setenv fw_setsys fw_loadenv; do
    ! command -v "$write_tool" >/dev/null 2>&1
done
fw_printenv -n ethaddr
```

这里保留 `30_uboot-envtools` 是预期行为：它在 RAM/tmpfs 中建立 `fw_printenv` 所需的
AX9000 `appsblenv` 读取配置，不保存 U-Boot 环境，也不得被替换成写入脚本。不要因为名称中含
`uci-defaults` 就删除它；应验证其内容不调用 `fw_setenv`、`fw_setsys`、`fw_loadenv`、`mtd`、
`ubiformat`、`nandwrite` 等写工具。

验证并记录：

- 设备型号和设备树匹配 Xiaomi AX9000；
- 内核完整启动，无持续 panic、oops、UBI/I/O 错误；
- `/proc/cmdline` 有且仅有一个 `root=/dev/ram0`；
- `/proc/cmdline` 不包含 `ubi.mtd=` 或 `/dev/ubiblock`；
- `rootfs` MTD 仍为 `0x0e800000`，但未被自动附加；全部 `/dev/mtd*` 的仅打开写模式探测都被内核拒绝；
- `/sys/class/ubi` 下没有 `ubi0`、`ubi1` 等持久 UBI 设备条目；
- `mount` 中没有来自 UBI、UBIFS、ubiblock 或原 `rootfs_data` 的挂载；
- 以太网接口、交换端口和 MAC 地址映射；
- Wi-Fi 射频是否被识别（本阶段不要求持久化配置）；
- LED、按键、温度传感器、USB（若测试）等；
- `official` 中没有第三方 NSS 加速/ECM/NSS firmware 模块、服务或专用配置；
- `nss` 中预期的 NSS firmware/module/ECM 状态可识别，且 packet steering 与 OpenWrt
  software/hardware flow offload 均保持关闭；
- 涉及 bridge VLAN filtering 或 NSS Wi-Fi 时，按 [NSS 限制](NSS.md#bridge-vlan-filtering-与-nss-wi-fi-限制)
  单独记录每个 VLAN 和转发方向，不把简单连通误当成兼容；
- AX9000 profile 未通过 `-uboot-envtools` 排除读工具，最终 `fw_*` 集合恰好为 `fw_printenv`、`fw_printsys`；
- `30_uboot-envtools` 存在，`05_fw_defaults` 与三个环境写工具不存在；
- runtime gate 精确记录 `fw_printenv_available=yes`、`uboot_env_write_tools=absent`；
- 持久 UBI 始终未附加、未挂载、未写入。

先只验证危险命令拒绝器，不提供任何参数：

```sh
for command in sysupgrade factoryreset firstboot jffs2reset jffs2mark mount_root; do
  "$command" >/tmp/"$command".out 2>&1
  test "$?" -eq 74 || { echo "guard failed: $command"; exit 1; }
done
```

每个命令都必须退出 74，且不得出现 UBI 附加、挂载或 MTD 写入。随后仍不得在 initramfs 中
以真实参数运行 `firstboot`、`jffs2reset`、`sysupgrade`、`mount_root`、`ubiattach` 或任何可能
初始化、附加、挂载、修改持久 UBI/overlay 的操作。不要主动附加或挂载原厂 UBI volume，
即使只计划只读访问也应停止并重新审查测试方案。

### 5.1 自动化运行时证据（最终门禁必需）

手工命令只用于现场观察。先创建 session，再在生产系统采集测试前状态；证据目录必须位于仓库
`hardware-evidence/` 下、权限为 `0700` 且初始化前完全为空。创建器用 `O_EXCL|O_NOFOLLOW` 一次性写入
严格 `SESSION.txt` 和 compare-verified `CANDIDATE.txt`；非空目录、重复初始化或符号链接都会失败：

```sh
EVIDENCE="$PWD/hardware-evidence/ax9000-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$EVIDENCE"
./scripts/create-hardware-session.sh "$EVIDENCE" "$PWD/dist-nss"
./scripts/collect-production-state.sh root@192.168.31.1 "$EVIDENCE" before
```

缺少、损坏或符号链接形式的 `SESSION.txt` 时，production/runtime collectors 必须在 SSH 前失败。
production collector 的 before/after 各只执行一次 SSH 事务并独占提交，输出 `production-capture-<phase>.txt`；
其 schema 2 metadata 绑定随机 challenge、session、phase、epoch/uptime、boot ID、board/MAC/fingerprint 与
cmdline/MTD/U-Boot env/production identity 四份原始 payload 摘要，禁止重复采集或覆盖。
按脚本输出完成 UART 中实际 RAM image SHA、十六进制 size、session、ethaddr 测量，并仅从 RAM
启动后执行：

```sh
./scripts/collect-runtime-evidence.sh \
  root@192.168.1.1 \
  "$PWD/dist-nss" \
  nss \
  "$EVIDENCE"
```

`official` 候选把目录和 flavor 改为 `dist`、`official`。collector 把 `SESSION.txt` 中的值作为
`ax9000-runtime-probe.sh` 第五参数。探针要求 cmdline 恰好一个 `root=/dev/ram0` 和恰好一个匹配
`nexawrt.session=<session>`，读取 `fw_printenv -n ethaddr`，并在 `device.txt` 与
`runtime-gate.txt` 写入相同：

```text
session_id=<SESSION.txt>
device_fingerprint_sha256=sha256("xiaomi,ax9000\nethaddr=<lowercase-mac>\n")
```

此外继续验证无持久 UBI、MTD 只读和 write-open 拒绝、危险命令退出 74、flavor 组件边界。
`device.txt`/`runtime-gate.txt` 使用严格 schema；额外或重复字段都失败。collector 只在路由器
`/tmp` 使用临时目录；本地三个 runtime payload 必须全部不存在，归档验证后以 `O_EXCL|O_NOFOLLOW`
一次性提交，禁止同一 session 重采、覆盖或跟随输出 leaf symlink。任一失败只清理本次创建的文件。

完整 UART 和 U-Boot 帮助记录仍须保存为 `uart-cold-boot.log`、`uboot-help.txt`；自动探针不能
替代实际加载缓冲区测量和恢复审核。

## 6. RAM 启动退出与回归

1. 保存完整 UART、`ram-boot.log` 和原始压力证据到开发机。
2. 通过正常重启或断电退出 RAM 系统；不得保存任何 U-Boot 环境。
3. 确认设备沿原路径启动当前生产系统。
4. 回到生产系统后，用同一 session 目录采集 after 状态并比较：

```sh
./scripts/collect-production-state.sh root@192.168.31.1 "$EVIDENCE" after
./scripts/verify-post-reboot-state.sh "$EVIDENCE"
```

比较器要求 before/after session 一致、challenge 不同、boot ID 不同、after epoch 更晚、设备 fingerprint
一致且 metadata 摘要与四份原始 payload 相符；随后要求生产 kernel cmdline、MTD 布局、完整 `fw_printenv`
和生产系统身份前后一致，且生产根必须精确为 `/dev/ubiblock0_1`。最终硬件门禁还会用生产 `ethaddr`
计算 fingerprint，与 UART、运行时及压力证据绑定到同一台 AX9000。只有比较成功才以独占创建写出
`post-reboot-gate.txt`；预置文件或 leaf symlink 都不能被覆盖。

## 7. flavor 运行时基线

### official

`official` 是默认基线。除上游目标本身依赖的 `kmod-qca-nss-dp` 外，不应出现第三方
NSS driver、ECM、NSS firmware 或 NSS 专用服务。发现后停止并检查 flavor 污染。

### nss

`nss` 必须使用仅 NSS overlay 中的 UCI defaults，并读取确认以下**正确 section/key**：

```sh
uci -q get network.globals.packet_steering
uci -q get firewall.@defaults[0].flow_offloading
uci -q get firewall.@defaults[0].flow_offloading_hw
```

三项都必须输出 `0`。本项目使用命名 section 写法 `network.globals`；upstream UCI 的
`network.@globals[0]` 也可以访问同一个首个 `globals` section。真正不应照搬的是参考
README 的 `network.@device[0]`，因为 packet steering 不属于该 `device` section。测试期间
不得临时打开 OpenWrt software/hardware flow offload 来“叠加”性能。

NSS/ECM 状态采集使用 `scripts/nss-diagnostics.sh`。该脚本只读并输出到 stdout，不会写闪存、
修改 UCI、挂载 debugfs 或加载模块。若需要保存输出，应由开发机通过 SSH 捕获 stdout，或在
已经批准的 RAM-only 环境中明确写入 `/tmp`；不要把日志写到持久 overlay。

## 8. official/NSS A/B 测试方法

本节只是**真机 RAM 启动获批后的验收设计**。截至目前批准尚未取得，不得因为已有 A/B
方案就加载或启动任何候选镜像，更不得刷写。

### 8.1 变量控制

- A 组为默认 `official`，B 组为实验性 `nss`；除 flavor 必需的源码、包、配置和
  `files-nss/` 外，其余 NexaWrt 安全补丁与 initramfs 约束保持一致；
- 使用同一台 AX9000、同一电源、客户端、服务端、网线、交换机端口、MTU、测试工具版本、
  流数量、方向、时长和环境温度范围；
- 初始比较使用简单有线、无 bridge VLAN filtering 的隔离拓扑。VLAN 和 NSS Wi-Fi 另设
  兼容性测试，不与基础吞吐数字混在一起；
- 每次启动都重新验证 `/proc/cmdline`、持久 UBI 未附加，以及实际 flavor/source 清单；
- 建议采用 A-B-B-A 或 B-A-A-B 顺序，降低温度、缓存、客户端状态和时间漂移造成的偏差。

### 8.2 每轮采集

在空闲、测试进行中和测试结束后分别记录：

- TCP 单流与多流、两个方向的吞吐；UDP 场景同时记录发送率、接收率、丢包和抖动；
- 空载延迟与负载下延迟，而不是只记录最高吞吐；
- 每核 CPU、load、softirq、相关 IRQ 计数与 affinity、温度和是否发生降频；
- firewall flow offload、packet steering、NSS firmware/module、ECM 连接状态；
- `dmesg` 中的 crash、warning、firmware timeout、ECM accelerate/decelerate 异常；
- bridge/VLAN/Wi-Fi 测试中的每个端口、VID、tagged/untagged、PVID、SSID、方向和隔离结果。

NSS 轮次运行只读诊断脚本；official 轮次也运行同一脚本，预期它清楚显示 NSS/ECM 不存在，
这样才能发现 flavor 污染。保存完整原始输出，不只抄录一个峰值。

### 8.3 24 小时压力门禁

短轮次 A/B 通过后，必须在隔离网络完成真实至少 86,400 秒压力测试：

```sh
./scripts/run-ax9000-stress-gate.sh \
  root@192.168.1.1 \
  "$EVIDENCE" \
  192.168.1.2 \
  500
```

吞吐下限必须在看结果前确定。脚本从 `SESSION.txt`/`runtime-gate.txt` 读取 session 与 fingerprint，
每轮 SSH 都重新确认：cmdline 恰好一个 RAM root、恰好一个匹配 session，并通过
`fw_printenv ethaddr` 重算相同 fingerprint。它至少完成 24 个双向 `iperf3` 轮次，同时拒绝
panic/oops、热节流、SSH 中断、iperf 失败或低于阈值。

生产模式重置 `PATH`，只使用权限受控的固定系统工具路径，并要求远端受信任的 `/usr/bin/iperf3`。每轮
network、thermal 与 kernel-health 记录都携带相同 round、wall-clock epoch、主机 monotonic timestamp、设备
boot ID 和设备 uptime；verifier 要求 boot ID 全程不变，uptime 严格递增且与主机 monotonic 进度一致，首尾
覆盖真实 86,400 秒区间、相邻间隔有上界且 wall/monotonic 漂移不超过 300 秒。
中断/失败只原子更新 `completed=no` 的 `stress-24h.log`，不生成通过 gate。成功路径先在临时证据目录
生成 `completed=yes` 候选并完整复验，通过后才原子替换正式日志，最后独占提交 `stress-gate.txt`。网络、
温度、kernel health、进度和最终 gate 的输出 leaf symlink 不能修改外部 victim。成功证据：

- `stress-24h.log`（schema 3，含 production execution mode、session/fingerprint、boot ID 和首末 uptime）；
- `network-regression.log`；
- `thermal.log`；
- `kernel-health.log`；
- `stress-gate.txt`（含相同 execution mode、session/fingerprint、boot ID 和首末 uptime）。

单独复验：

```sh
./scripts/verify-stress-evidence.sh "$EVIDENCE"
```

默认 verifier 只接受 `execution_mode=production`。自动化回归只有显式设置 `NEXAWRT_TEST_MODE=1` 才能使用
加速时钟/工具替身，并生成 `execution_mode=test`；这类证据只能用
`verify-stress-evidence.sh --allow-test` 做测试复验，最终硬件门禁会拒绝。

### 8.4 重复与判定

- 每个条件至少完成 3 个有效重复；报告中位数、范围/离散度和所有异常轮次，不挑最好结果；
- 任一轮出现 panic/oops、网络失联、firmware timeout、VLAN/防火墙隔离回归、意外启用
  OpenWrt flow offload、持久 UBI 被附加或无法恢复生产系统，均判为失败并停止；
- “ECM accelerated”只能证明连接进入某个加速状态，不能单独证明端到端性能提高；
- 在数据经过复核前不得宣称“实际提速”或给出项目级性能百分比。结论必须限定设备、拓扑、
  协议、方向、MTU、并发、镜像 revision 和测试日期。

## 9. 结果记录模板

```text
日期/操作者：
设备标签：
基线固件：
flavor：official / nss
源码仓库/branch/commit：
镜像文件（artifact 名含 flavor）：
镜像 SHA-256：
镜像字节数 / U-Boot 十六进制 filesize：
双构建 Kconfig user/domain 与 8 位 source-lock revision 固定且可复现：PASS / FAIL
构建日志凭据扫描（小写 token 拒绝、大写 GHS_ 不误报）：PASS / FAIL
SESSION.txt（64 位小写 hex）：
CANDIDATE.txt 与重新验证的双构建/source-feed-lock receipt 一致：PASS / FAIL
备份目录与 SHA256SUMS 校验：PASS / FAIL
UART 中断及生产系统恢复（至少两次）：PASS / FAIL
UART 实际 image SHA/size/session/ethaddr 各恰好一次：PASS / FAIL
RAM 加载：PASS / FAIL
真机 RAM 启动批准记录：PASS / FAIL
initramfs 启动：PASS / FAIL
RAM-test 使用且仅使用一个 root=/dev/ram0：PASS / FAIL
命令行仅有一个匹配 nexawrt.session：PASS / FAIL
UART/生产 env/runtime/stress fingerprint 同一设备：PASS / FAIL
命令行不含 ubi.mtd= 或 /dev/ubiblock：PASS / FAIL
持久 UBI 未附加、未挂载、未写入：PASS / FAIL
全部 MTD 分区内核只读且 raw write-open 探测被拒绝：PASS / FAIL
profile 未排除 uboot-envtools，最终 fw_* 仅有 fw_printenv/fw_printsys：PASS / FAIL
只读 envtools（30 存在，05/三个写工具不存在）：PASS / FAIL
runtime 字段 fw_printenv_available=yes、uboot_env_write_tools=absent：PASS / FAIL
生产布局回归一致：PASS / FAIL
official 无第三方 NSS/ECM/firmware，或 nss 来源与组件清单匹配：PASS / FAIL
NSS 基线三项均为 0（仅 nss）：PASS / FAIL / N/A
NSS 只读诊断日志（仅 nss）：
A/B 拓扑、工具版本、轮次和原始数据位置：
无闪存写入：PASS / FAIL
重启回当前生产系统：PASS / FAIL
异常与日志位置：
结论：
```

任一关键项为 FAIL 时，不得加载候选，更不得进入闪存安装讨论；任何 PASS 仍只批准精确镜像的 RAM-only 测试，绝不批准 `saveenv` 或刷写。
