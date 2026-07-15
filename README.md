# NexaWrt

**NexaWrt** 是一个以可重复构建、设备适配和审慎验证为目标的 OpenWrt 衍生项目。
当前开发阶段**仅支持 Xiaomi AX9000**，并且只针对此前只读检查识别出的
**single-large-UBI v1** 闪存布局。关键几何参数仍必须由本地备份脚本再次核对；
脚本若拒绝当前布局，就不能继续。

当前 NexaWrt 仅是面向该设备的 **initramfs RAM-test**，不是刷机包，禁止持久化刷写。
其他设备、其他 AX9000 分区布局以及后续支持范围都必须另行适配和验证；本仓库不对
未来支持的型号、功能或时间表作承诺。**截至目前，真机 RAM 启动尚未获得批准，也未完成。**

> [!CAUTION]
> NexaWrt 当前仓库和工作目录中**未发现任何这台设备的既有备份**。在完成原机只读备份，
> 并分别验证 UART、U-Boot 操作路径和 initramfs RAM 启动之前，**不得对闪存执行
> 任何写入、擦除、升级或分区调整操作**。当前阶段禁止生成、发布或使用持久化刷写产物。

## 当前支持与安全边界

- 设备：Xiaomi AX9000
- 默认 `official` flavor 上游基线：OpenWrt `v25.12.5`，提交前缀 `f0a60eee...`
- 可选 `nss` flavor 上游：`manifests/nss.lock` 锁定 `qosmio/openwrt-ipq` 的 `25.12-nss` 和固定 commit；它是实验性对照组，绝非默认
- 当前布局：single-large-UBI v1
- `rootfs` MTD 预期偏移：`0x01180000`（必须重新读取确认）
- `rootfs` MTD 大小：`0x0e800000`（232 MiB）
- 小米原厂/当前生产布局基线 UBI volumes：
  - volume 0：`kernel`
  - volume 1：`rootfs`
  - volume 2：`rootfs_data`
- 小米原厂/当前生产布局基线启动参数：`root=/dev/ubiblock0_1`（仅用于记录原系统，不是 NexaWrt RAM-test 参数）
- NexaWrt initramfs RAM-test 必须使用的启动参数：`root=/dev/ram0`
- NexaWrt RAM-test 内核命令行：**不得出现** `ubi.mtd=` 或 `/dev/ubiblock`
- 持久 UBI：RAM-test 期间必须保持未附加、未挂载、未写入
- `official` flavor 不引入第三方 NSS 加速栈/ECM/NSS firmware（上游目标默认依赖的 `kmod-qca-nss-dp` 除外）
- `nss` flavor 才可引入锁定的 NSS/ECM 栈和专有 firmware；必须保持 flavor 身份、来源与诊断记录
- 当前阶段唯一可能允许的启动方式：**经单独批准后，通过 U-Boot 将 initramfs 加载到 RAM 并启动**

任何一项与现场设备不符，都必须停止。不要假设另一台同型号设备具有相同布局。
当前尚未满足真机 RAM 启动批准条件；文档中的测试步骤不是现阶段的执行授权。

## 关键未决风险：U-Boot 能否读取整个 UBI

本项目把 Linux 设备树中的 `rootfs` 定义为 `0x01180000 + 0x0e800000`。这个大小是为了
匹配此前从当前设备读到的 232 MiB MTD，**不是**把官方 `ubi_kernel` 与 `rootfs` 两段机械
相加后的 `0x0ee80000`。末尾约 6.5 MiB 的差异在重新读取真实设备前不能擅自“补齐”。

更重要的是，修改 DTS 只会改变 Linux 看到的分区，不会自动改变 U-Boot 内置的
`mtdparts`、启动脚本或 UBI 可见范围。如果 U-Boot 只能扫描旧的较小范围，而 Linux/UBI
长期磨损均衡把 `kernel` volume 的物理擦除块移动到该范围之外，设备可能在一次正常重启后
无法启动。因此，以下项目属于任何持久化研究的**硬阻断项**：

- 通过 UART 只读保存完整 `printenv`、`mtdparts`、`bootcmd` 和相关启动脚本；
- 在不执行 `saveenv`、擦除或写入的前提下，确认 U-Boot 的 `ubi part`/`ubi info`/读取命令
  实际覆盖整个预期 `rootfs` 区域；
- 证明 U-Boot 能按 volume 名称/编号稳定读取 `kernel`，且边界与 Linux 完全一致；
- 由独立审查确认长期 UBI 磨损均衡不会把启动必需数据移动到 bootloader 不可见区域。

在这些问题解决前，即使 initramfs 测试全部通过，仍然只允许 RAM 启动，**不得生成、发布
或使用 sysupgrade/factory 等持久化刷写镜像**。

## 当前阶段边界

NexaWrt 当前阶段的目标只是证明：

1. 能通过 UART 稳定观察并中断 U-Boot；
2. 能读取和记录启动环境、MTD/UBI 布局及当前启动日志；
3. 证明候选 initramfs 的命令行为 `root=/dev/ram0`，且不包含 `ubi.mtd=` 或 `/dev/ubiblock`；
4. 在获得单独批准后，把匹配的 initramfs 镜像加载到 RAM；
5. 能在**不附加持久 UBI、不写闪存**的前提下启动 OpenWrt，并验证基本硬件与网络；
6. 重启或断电后仍可回到当前生产系统。

当前阶段明确禁止：

- 直接刷写任何 OpenWrt 官方 sysupgrade/factory 镜像；
- `mtd write`、`mtd erase`、`flash_erase`、`nandwrite`、`ubiformat`；
- `ubimkvol`、`ubirmvol`、`ubirsvol` 或其他会改变 UBI 的命令；
- `sysupgrade`、修改 bootcmd/启动槽、保存未经审查的 U-Boot 环境；
- 写入 `appsbl`、`appsbl_1`、`appsblenv`、`art`、`bdata`、`bootconfig`、
  `bootconfig1` 或 `rootfs`；
- 使用为其他分区布局、其他提交制作的镜像，或把 `official`/`nss` flavor 的包、overlay、缓存和产物混用。

## 开始前

1. 阅读 [恢复说明](docs/RECOVERY.md)，准备 UART、当前启动记录和恢复路径。
2. 使用 `scripts/backup-router.sh` 进行原机只读备份，并把备份复制到另一块可靠介质。
3. 校验 `SHA256SUMS`，确认关键 MTD 均已成功读取且大小匹配 `/proc/mtd`。
4. 按 [测试说明](docs/TESTING.md) 逐项记录结果。
5. 完成候选镜像命令行与持久 UBI 隔离审查后，仍须取得明确批准，才可以安排真机
   initramfs RAM 启动；目前尚未批准，且任何阶段都不得写闪存。

## 只读备份

```sh
./scripts/backup-router.sh --output "$HOME/ax9000-backups/ax9000-$(date +%Y%m%d-%H%M%S)"
```

建议把输出放在仓库外；默认目录名也已被 `.gitignore` 明确排除。脚本默认连接
`root@192.168.2.1`，支持 SSH key 或 SSH 自带的交互认证；它不会接收、
保存或转发密码参数，也不依赖 `sshpass`。可通过选项指定主机、用户、端口和本地输出目录：

```sh
./scripts/backup-router.sh --host 192.168.2.1 --user root --port 22
```

脚本只从路由器读取信息和 MTD，不在远端创建文件。它会采集 `/proc/mtd`、`ubinfo`、
`dmesg`、`fw_printenv`，并读取以下关键 MTD：

`appsblenv`、`appsbl`、`appsbl_1`、`art`、`bdata`、`bootconfig`、
`bootconfig1`、`rootfs`。

备份目录权限默认为仅当前用户可访问，并在本地生成 `SHA256SUMS`。脚本不会单独导出
`/etc/config`、密码数据库、SSH 私钥、无线凭据或其他明确的敏感配置。但 `rootfs` 原始
MTD 备份包含整个 UBI 区域，可能间接包含 `rootfs_data` 中的配置和密钥，因此仍应把
整个备份目录视为敏感材料，离线保存且不要上传到仓库或公开网盘。

## 文档

- [恢复与安全边界](docs/RECOVERY.md)
- [initramfs 测试流程](docs/TESTING.md)
- [实验性 NSS flavor、限制与诊断](docs/NSS.md)


## 构建 NexaWrt

NexaWrt 提供两个相互隔离的构建 flavor：

- `official`：默认；使用 `manifests/upstream.lock` 中的 OpenWrt `v25.12.5` / 固定 commit，
  官方 feeds 也按该 tag 自带的 commit 锁定；
- `nss`：实验性、可选；`manifests/nss.lock` 把 `qosmio/openwrt-ipq` 的 `25.12-nss`
  锁定到 commit `d6848fa2ea00193b5b7d3973e3990da7f608027c`，并固定 NSS feeds、叠加仅属于
  NSS 的配置与 overlay。它依赖侵入性的下游网络栈、ECM 和专有
  NSS firmware，且与 OpenWrt packet steering、software/hardware flow offload 冲突。
  首个实验 flavor 明确关闭 ath11k NSS Wi-Fi、mesh 与 NSS SQM，只验证有线基础路径。

`official` 始终是默认和 Pull Request 构建 flavor。GitHub Actions 手动触发时才提供
`official`/`nss` 选择，artifact 名会包含实际 flavor。NSS 的风险、bridge VLAN filtering、
NSS Wi-Fi 限制和只读诊断方法见 [NSS 文档](docs/NSS.md)。两个 flavor 都必须经过同一套
RAM-only 命令行覆盖、持久 MTD 只读标记、独立镜像身份和持久升级 fail-closed 门检；
仓库安全补丁对 official 与 nss 两个锁定 source commit 都先校验再严格应用。

先做不联网的静态检查：

```sh
./scripts/validate.sh
```

在 Linux 构建机上完整构建默认 `official` flavor：

```sh
./scripts/build.sh
```

NSS 不是隐式 fallback。只有明确选择 `nss` 时才允许使用 NSS 构建路径；本地 Linux
构建使用：

```sh
NEXAWRT_FLAVOR=nss ./scripts/build.sh
```

不要通过修改 `official` 的 source、配置或 `files/` 来模拟 NSS。

macOS 自带的 Bash、Make 和默认大小写不敏感文件系统通常不满足 OpenWrt 完整构建
要求。本机建议只做静态检查和只读备份，固件通过 GitHub Actions 的
**NexaWrt AX9000 initramfs build** 工作流手动构建。

两个 flavor 的安全构建流程都只允许 AX9000 single-large-UBI initramfs profile，artifact 名
必须能追溯到 flavor，镜像文件名必须能追溯到 profile。当前 profile 明确关闭 sysupgrade 和
factory 产物，产物门检会拒绝任何可刷写镜像。

现有 tag release workflow 保持默认 `official`，其 `dist/` 发布目录只包含：

- `*-xiaomi_ax9000_single_ubi-initramfs-uImage.itb`：当前阶段 RAM 启动测试；
- `DO-NOT-FLASH.txt`、构建清单、profile 信息和 SHA-256。

实验性 `nss` 只通过手动 build workflow 上传独立的 `dist-nss/` allowlist staging 目录，
不会上传整个 OpenWrt target 输出，也不进入现有 tag release workflow。`dist-nss/` 只包含精确的
AX9000 single_ubi initramfs ITB、允许的构建 metadata、NSS 来源清单、第三方 notice、
`DO-NOT-FLASH.txt` 与 SHA-256；它不应被描述成正式发布。

> 当前阶段只生成和发布 initramfs 候选产物，并且只能设计为从 RAM 启动。候选镜像必须使用
> `root=/dev/ram0`，不得包含 `ubi.mtd=` 或 `/dev/ubiblock`。若任何构建目录中出现
> sysupgrade/factory 文件，产物门检必须失败。当前候选产物尚未获得真机 RAM 启动批准。


## License

除另有明确标注的上游或第三方组件外，本仓库采用 **GNU General Public License v2.0 only
（GPL-2.0-only）**。引入、引用或构建的 OpenWrt 上游代码、软件包、补丁及其他第三方组件
继续适用其各自的许可证、版权声明和附加条款；本仓库的许可证声明不会替代这些条款。

本说明仅用于描述项目的许可意图，不构成法律意见或法律保证。发布、再分发或组合使用前，
使用者应自行核对相关组件的实际许可要求。

## 目录结构

```text
configs/                 单设备、按 flavor 隔离的最小包配置
files/                   两个 flavor 共用、不含密码或订阅的基础 overlay
files-nss/               仅 NSS flavor 应用的运行时 overlay
manifests/               OpenWrt/feeds/layout 与 NSS 来源锁定信息
patches/                 对两个锁定 source commit 都严格应用的 RAM-only 安全补丁
scripts/backup-router.sh 只读备份
scripts/nss-diagnostics.sh NSS/ECM 只读运行时诊断
scripts/prepare.sh       获取并校验上游
scripts/build.sh         Linux 完整构建
scripts/validate.sh      静态、源码和产物门检
tests/                   静态门检与只读备份保护测试
.github/workflows/       手动构建及 tag 发布
```
