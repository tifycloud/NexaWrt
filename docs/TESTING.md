# NexaWrt：Xiaomi AX9000 initramfs 测试流程

本流程只适用于 **NexaWrt 当前支持的 Xiaomi AX9000 single-large-UBI v1 布局**，
并且只覆盖 **initramfs RAM 启动测试**。它不包含安装、sysupgrade、UBI 重建或任何
闪存写入步骤；其他设备或布局必须另行制定测试流程，本文不构成未来支持承诺。
默认测试对象是 `official` flavor；`nss` 只是由 `manifests/nss.lock` 锁定到
`qosmio/openwrt-ipq` `25.12-nss` / `d6848fa2...` 的实验性可选对照组。**当前尚未完成任何 flavor 的真机 RAM 启动批准；
本文是验收流程，不是执行授权。**

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

## 2. UART 与 U-Boot 预检

1. 使用 3.3 V UART，仅连接 TX/RX/GND，不接 5 V。
2. 冷启动并保存完整日志。
3. 中断 U-Boot，只执行已确认无副作用的帮助、环境打印和内存信息命令；保存
   `printenv`、`mtdparts`、`bootcmd` 及相关启动变量。
4. 若 U-Boot 提供 UBI 信息/读取命令，先用 `help` 核对语义；只读记录它实际扫描的分区和
   volume，禁止执行 create/remove/write/erase。不能确认命令无副作用时就不要执行。
5. 不执行 `saveenv`，不修改 bootcmd、启动槽或闪存。
6. 继续当前启动，确认系统可正常返回。
7. 至少重复两次，以排除偶发串口或供电问题。

通过标准：每次均能可靠观察、输入、中断并恢复当前启动，且未产生环境持久化变化。

## 3. initramfs 镜像门检

加载前记录镜像的：

- 完整文件名和字节大小；
- SHA-256；
- flavor（`official` 或 `nss`）及对应 artifact 名；
- `official` 的 OpenWrt tag `v25.12.5` 与提交前缀 `f0a60eee...`，或 `nss` 的
  `qosmio/openwrt-ipq` `25.12-nss` 固定 commit `d6848fa2ea00193b5b7d3973e3990da7f608027c`；
- NexaWrt 当前 AX9000 补丁、配置、feeds 和 overlay 清单；
- `official` 明确不含第三方 NSS 加速栈/ECM/NSS firmware；`nss` 明确列出 NSS/ECM
  包、firmware 来源及其许可证检查结果；
- 构建日志和配置；
- 候选命令行明确使用 `root=/dev/ram0`，且不含 `ubi.mtd=` 或 `/dev/ubiblock`；
- 启动流程审查证明不会自动附加、挂载或写入持久 UBI；
- 针对本次真机 RAM 启动的明确批准记录。

只接受 initramfs RAM 启动产物。不要把官方 factory/sysupgrade 镜像或其他布局镜像当作
NexaWrt 测试镜像，也不要执行任何“先刷进去再试”的步骤。

## 4. U-Boot RAM 加载

不同 U-Boot 版本的网络加载命令、RAM 地址和启动命令可能不同，因此必须以现场 `help`、
`printenv` 和内存布局为准。本仓库不提供可盲目复制的固定地址。

安全原则：

1. 只把 initramfs 镜像下载到已确认安全的 RAM 地址；
2. 在 RAM 中校验已加载长度和哈希（若 U-Boot 支持）；
3. 只执行与镜像格式匹配的 RAM 启动命令；
4. 不运行任何包含 `nand`、`mtd`、`ubi` 写操作或 `saveenv` 的命令；
5. 全程记录 UART 输出。

若加载地址、镜像格式、设备树或启动命令有疑问，停止，不猜测。

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
```

验证并记录：

- 设备型号和设备树匹配 Xiaomi AX9000；
- 内核完整启动，无持续 panic、oops、UBI/I/O 错误；
- `/proc/cmdline` 有且仅有一个 `root=/dev/ram0`；
- `/proc/cmdline` 不包含 `ubi.mtd=` 或 `/dev/ubiblock`；
- `rootfs` MTD 仍为 `0x0e800000`，但未被自动附加；
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
- 持久 UBI 始终未附加、未挂载、未写入。

不要在 initramfs 中运行 `firstboot`、`jffs2reset`、`sysupgrade`、`mount_root`、`ubiattach`
或任何可能初始化、附加、挂载、修改持久 UBI/overlay 的操作。不要主动附加或挂载原厂
UBI volume，即使只计划只读访问也应停止并重新审查测试方案。

## 6. RAM 启动退出与回归

1. 保存 initramfs 的完整串口和 `dmesg` 输出到开发机。
2. 通过正常重启或断电重启退出 RAM 系统。
3. 不保存 U-Boot 环境。
4. 确认设备重新沿原路径启动当前生产系统。
5. 回到生产系统后，再次采集 `/proc/cmdline`、`/proc/mtd`、`/sys/class/ubi`、
   `fw_printenv` 和启动日志，与生产基线比较。

通过标准：当前生产系统可正常启动；MTD/UBI 布局、启动环境和可观察配置没有因测试发生变化。

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

### 8.3 重复与判定

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
备份目录与 SHA256SUMS 校验：PASS / FAIL
UART 中断及生产系统恢复（至少两次）：PASS / FAIL
RAM 加载：PASS / FAIL
真机 RAM 启动批准记录：PASS / FAIL
initramfs 启动：PASS / FAIL
RAM-test 使用 root=/dev/ram0：PASS / FAIL
命令行不含 ubi.mtd= 或 /dev/ubiblock：PASS / FAIL
持久 UBI 未附加、未挂载、未写入：PASS / FAIL
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

任一关键项为 FAIL 时，不得进入闪存安装讨论。
