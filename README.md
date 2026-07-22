## 当前状态

当前阶段是 **RAM-test release candidate**，不是可刷写固件。仓库已经加入双构建可复现性、SBOM、构建证据、GitHub attestation、内核 MTD 只读、运行时危险命令拒绝器和签名真机证据门禁；但在真实 AX9000 的 UART、恢复、回归和 24 小时压力证据完成前，仍不批准 RAM 启动，更不批准持久写入。

完整门禁见 [docs/PRODUCTION-READINESS.md](docs/PRODUCTION-READINESS.md)。

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
- 持久 UBI：RAM-test 期间必须保持未附加、未挂载、未写入；项目 DTS 还将 appsblenv、bdata、pstore、rootfs 与原有固件分区统一标记为内核只读
- 两个 flavor 都启用裁剪后的只读 `uboot-envtools`：仅保留 `fw_printenv`、`fw_printsys` 与在 RAM/tmpfs 生成 AX9000 `appsblenv` 读取配置的 `30_uboot-envtools`；AX9000 profile 只能排除 `-ubi-utils -mtd`，不得出现 `-uboot-envtools`，否则 OpenWrt `merge_packages` 会覆盖 seed config 并把读工具移出镜像；仍禁止 `fw_setenv`、`fw_setsys`、`fw_loadenv` 和 `05_fw_defaults`
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
- [生产就绪门禁与真机证据格式](docs/PRODUCTION-READINESS.md)
- [版本化 RAM-test prerelease 发布说明](docs/RELEASES.md)


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

`uboot-envtools` 不是被笼统禁用的包。两个 flavor 都需要它提供 `fw_printenv`，以只读取得
`ethaddr` 并绑定真机证据。`patches/003-uboot-envtools-read-only.patch` 删除所有随包安装的环境
写入口和 `05_fw_defaults`，但刻意保留 target-specific `30_uboot-envtools`；后者只在 initramfs
RAM/tmpfs 中生成读取定位配置。源码门禁和最终 rootfs 门禁都会要求该脚本存在并扫描其内容，同时
确保镜像内 `fw_*` 工具恰好只有 `fw_printenv`、`fw_printsys`。此外，AX9000 image profile 的
`DEVICE_PACKAGES` 必须恰好为 `-ubi-utils -mtd`：不能加入 `-uboot-envtools`，因为 OpenWrt
`merge_packages` 的显式负包会压过 `CONFIG_PACKAGE_uboot-envtools=y`。任何 `saveenv` 或 flash
写入仍被禁止。

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

构建不会再让 OpenWrt 在源码顶层随机生成 APK 私钥，也不会把长期私钥交给联网的第三方构建机。
当前 initramfs 构建采用**仅公钥信任身份**：仓库提交 `manifests/apk-signing-public.pem`，其规范化
SubjectPublicKeyInfo DER SHA-256 由 `manifests/apk-signing.lock` 锁定；OpenWrt 只嵌入该受信公钥，构建期
临时 package index 保持未签名并以显式 `--allow-untrusted` 安装。对外软件库使用另一套独立 P-256 身份：
固件只内置仓库公钥和 `packages.adb` URL，受保护的 `package-repository` GitHub Environment 只在受信任的
`main` 发布 job 中临时提供仓库外私钥，用它单独签署 index，随后删除；私钥不会进入固件构建、artifact、日志或 Pages。

生产构建使用已提交的公钥：

```sh
export NEXAWRT_APK_SIGNING_PROFILE=production
export NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$PWD/manifests/apk-signing-public.pem"
./scripts/build.sh
```

本地双构建也可使用 `repro-test`，但必须显式提供一个位于仓库与 OpenWrt `TOPDIR` 之外、不可由其他
用户写入、无符号链接/硬链接的 P-256 **公钥**，并设置其规范化 DER SHA-256：

```sh
export NEXAWRT_APK_SIGNING_PROFILE=repro-test
export NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE=/absolute/path/nexawrt-repro-test-public.pem
export NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$(
  openssl pkey -pubin -in "$NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE" -outform DER 2>/dev/null |
    sha256sum | awk '{print $1}'
)"
NEXAWRT_FLAVOR=nss ./scripts/build.sh
```

`repro-test` 只能做本地确定性预检，最终硬件批准会拒绝它。生产私钥保存在仓库外，不得提交到 Git、
GitHub secret、OpenWrt `TOPDIR`、构建 evidence、artifact、SBOM 或 verified dist。

不要通过修改 `official` 的 source、配置或 `files/` 来模拟 NSS。

macOS 自带的 Bash、Make 和默认大小写不敏感文件系统通常不满足 OpenWrt 完整构建
要求。本机建议只做静态检查和只读备份。要从浏览器构建并下载最新候选：进入 GitHub
**Actions → NexaWrt AX9000 browser verified build → Run workflow**，选择 `official` 或 `nss`。
工作流会执行两个隔离的干净构建、校验 GitHub provenance 和字节级可复现性；成功后在本次运行页面
**Artifacts** 区域下载 `NexaWrt-AX9000-<flavor>-verified-dist-<commit>`。该下载仍是 RAM-only
真机测试候选，不是可直接写入闪存的生产刷机包。

### 自建签名 APK 软件库

OpenWrt 25.12 已使用 APK，不再使用 OPKG/IPK。NexaWrt 会把 testing 仓库 URL 和独立公钥直接编译进 AX9000 rootfs；启动后可直接执行 `apk update`、`apk search` 和 `apk add`。GitHub Actions 从固定源码构建审核包，签署 `packages.adb`，创建不可覆盖的版本 Release；Pages 再根据 GitHub asset digest 和归档内摘要安全发布到 `https://tifycloud.github.io/NexaWrt/packages/25.12/testing/aarch64_cortex-a53/`。

当前仓库基础设施已经按 `manifests/package-repository.lock` 和 `manifests/package-repository-packages.txt` 锁定，但频道仍是 `testing`。社区组件目录不会自动进入受信软件库；每个软件必须完成源码固定、许可证和构建脚本审查、APK 构建及安装测试。AX9000 当前仍是 RAM-only，运行时安装的软件重启后不会持久保存。设计、命令和 stable 门禁见 [docs/PACKAGE-REPOSITORY.md](docs/PACKAGE-REPOSITORY.md)。

### 浏览器自选组件云编译

GitHub Pages 的 **组件 / Components** 区域读取仓库审核过的 `components/catalog.json`，支持 x86_64 和 Xiaomi AX9000、组件搜索、依赖自动补齐与冲突阻止。网页只生成规范化请求和 request hash，不保存 GitHub token，也不接受任意软件包、脚本、路径或 UCI 输入。

登录 GitHub 后打开 **Actions → NexaWrt custom component build → Run workflow**，按页面给出的 `target`、`flavor` 和 `components` 输入启动构建。空 `components` 表示仅使用目标默认组件；非空值只能是目录中的组件 ID。构建成功后从该次运行的 **Artifacts** 下载带 `custom-build-manifest.json` 和 `SHA256SUMS` 的产物。自定义产物是按需构建结果，不会自动冒充正式 Release；AX9000 产物仍受 RAM-only/真机门禁约束。

软件包选择器同时加载 SHA-256 绑定的中文用途目录，为全部官方与社区候选包提供中文用途说明，并保留上游英文描述供核对。这里的 **100% 覆盖** 包含人工整理的 `exact`、按软件家族规则生成的 `family` 和按分类保守概述的 `category`，不代表每一条都经过逐包人工审阅。生成、验证、质量层级和维护规则见 [docs/PACKAGE-PURPOSES-ZH.md](docs/PACKAGE-PURPOSES-ZH.md)。

两个 flavor 的安全构建流程都只允许 AX9000 single-large-UBI initramfs profile，artifact 名
必须能追溯到 flavor，镜像文件名必须能追溯到 profile。当前 profile 明确关闭 sysupgrade 和
factory 产物，产物门检会拒绝任何可刷写镜像。

候选发布有两个互不重叠且严格版本化的 tag 家族：`ram-test-vMAJOR.MINOR.PATCH-rc.N` 只对应
`official`，`ram-test-nss-vMAJOR.MINOR.PATCH-rc.N` 只对应实验性 `nss`。例如首个 NSS 测试版本可使用
`ram-test-nss-v0.1.0-rc.1`。preflight 会从严格受信任的 tag 名 fail-closed 派生
flavor，不允许未知 tag 回退到默认构建。每个 flavor 都执行两个无共享下载缓存、使用独立
flavor/replica `WORK_DIR`、构建日志和 staging 目录的干净构建，再把正确 flavor 传给比较器，
比较精确 ITB、package manifest、解析配置、buildinfo、输入摘要及规范化 CycloneDX SBOM。

浏览器手动构建和 tag 发布的每个副本 job 上传后都生成 schema-2 canonical producer descriptor，绑定 run、replica、artifact ID/name、
`SHA256SUMS` 摘要、精确 source ref/source digest，以及实际 workflow ref/signer digest，并以 descriptor 作为 GitHub provenance
attestation subject；compare job 从本次 workflow run 的 API 取得两个不同 artifact ID，使用 source/ref/signer digest 约束离线验证，
再把外部 producer identity 与 APK 信任 profile/规范化公钥 SHA-256、`mode=public-key-only`、`index_signed=false` 写入 schema-5
`REPRODUCIBILITY.json`，并将 descriptor 与 bundle 一同固化进 verified dist。
后续复验只接受显式绝对路径且 SHA-256 已绑定的 GitHub CLI，不从通用 `PATH` 搜索 verifier。本地 `local-unattested` 比较结果只能预检，不能
进入真机生产批准。只有可复现门禁通过，受保护的 `ram-test-release` Environment 才能发布 prerelease，
并继续为 ITB、SBOM、最终 `SHA256SUMS` 和精确 verified-dist archive 生成 GitHub provenance attestation。
Actions artifact 与 replica 路径包含 flavor，避免 official/NSS 候选混淆。发布资产还包含构建证据归档、
`BUILD-MANIFEST.txt`、`DO-NOT-FLASH.txt` 与 `REPRODUCIBILITY.json`；NSS 候选另外包含第三方
notice 和锁定 NSS firmware 的许可证副本。两条 tag 发布路径都只发布 AX9000 `single_ubi`
initramfs RAM-boot 候选，不上传整个 OpenWrt target 输出，也不开放 sysupgrade/factory 或任何
刷写路径。

> 当前阶段只生成和发布 initramfs 候选产物，并且只能设计为从 RAM 启动。候选镜像必须使用
> `root=/dev/ram0`，不得包含 `ubi.mtd=` 或 `/dev/ubiblock`。若任何构建目录中出现
> sysupgrade/factory 文件，产物门检必须失败。当前候选产物尚未获得真机 RAM 启动批准。


## 虚拟机测试、Releases 与下载网站

仓库提供独立的 **VM-only** QEMU 冒烟测试，覆盖 `x86-64` 与 `armsr-armv8` 两个架构。它使用
SHA-256 锁定的 OpenWrt ImageBuilder，检查启动、SSH、LuCI HTTP、`ubus`、UCI、网络和核心服务，
并把 VM 镜像、串口日志与结构化报告上传到 Actions。VM 产物会明确标记
`NOT_AX9000_FIRMWARE=1`、`HARDWARE_VALIDATION=0`、`NSS_VALIDATION=0`：**虚拟机通过只能证明通用
OpenWrt 用户空间和自动化流程可运行，不能证明 AX9000、Qualcomm NSS、交换芯片、Wi-Fi、温度、
断电恢复或持久存储安全。**

VM 有两条彼此隔离的路径：

- **VM smoke (QEMU only)**：覆盖 `x86-64` 与 `armsr-armv8`，注入一次性 CI SSH 公钥，只用于仓库自动化冒烟检查，不发布给用户。
- **NexaWrt x86_64 VM release**：只构建 `x86-64` 用户发行镜像，不注入任何 SSH 公钥、默认禁用 Dropbear。当前 `vm-x86_64/v2` 合同发布五种镜像：raw BIOS、BIOS Live ISO、EFI Live ISO、BIOS VMDK 和 EFI VMDK。工作流分别用 SeaBIOS/OVMF 对即将发布的五个精确文件执行双网卡 QEMU 运行时检查，验证静态管理 LAN `192.168.8.1/24`、DHCP WAN、firewall4/nftables、LuCI HTTPS、HTTP 重定向、独立首次启动密码、SSH 默认关闭，以及 raw/导入 VMDK 的重启持久化；通过后发布独立的 `vm-x86_64-vX.Y.Z-rc.N` prerelease。两份 ISO 都是 **Live 镜像，不是安装器**，配置不保证持久；两份 VMDK 是 `streamOptimized` VMware 导入传输格式，必须由 ESXi 导入/转换成 datastore 中的可写磁盘，不能把下载文件直接当作长期可写基础盘。自动化仍不能冒充真实 ESXi；稳定版只能在提交并验证机器可读的真实 ESXi 验收证据后，从精确 RC 资产原位晋级，不允许重编译。

在浏览器中打开 **Actions → NexaWrt x86_64 VM release → Run workflow**，必须选择 `main` 并填写例如
`vm-x86_64-v0.1.0-rc.1`。预检从 GitHub 远程读取当时的 `main` 精确 commit SHA，要求 dispatch 的
`GITHUB_SHA` 与之完全一致，再在该 SHA 创建轻量 tag；构建、证明和发布阶段都继续固定并复验同一个 SHA，
不是“任意 `main` 祖先”即可发布。新 `vm-x86_64/v2` Release 精确包含 21 个资产：五个镜像及各自的
`.sha256`、统一 manifest、安全标签、使用说明、33-key QEMU 报告、`SHA256SUMS`，以及 raw BIOS、
BIOS ISO、EFI ISO、BIOS VMDK、EFI VMDK 和 `SHA256SUMS` 六份 provenance。

Pages 当前生成 schema-v4 索引，同时保留对历史 `vm-x86_64/v1` 候选的兼容：历史 v1 仍按精确 9 资产、
15-key `artifact-labels.env`、23-key `smoke-report.txt` 和两份 provenance 验证；新 v2 必须满足精确
21 资产、18-key 标签、33-key 报告和六份 provenance。前端也继续接受已有 schema-v3 的历史 v1 数据。
所有候选都必须是 immutable prerelease，并通过 Release 身份、文件大小、SHA-256、attestation 和 proof
逐项绑定后才会在独立的 x86_64 VM 区域提供下载。任一项失败只隐藏 VM 条目，不会把 VM PASS 升级成
AX9000 可刷写或生产结论。完整规则和使用说明见 [VM x86_64 文档](docs/VM-X86_64.md)。

测试阶段的 AX9000 候选仍通过轻量 tag 发布为 GitHub prerelease：

```sh
tag=ram-test-nss-v0.1.0-rc.1
commit="$(git rev-parse origin/main)"
git merge-base --is-ancestor "$commit" origin/main
git tag "$tag" "$commit"
git push origin "refs/tags/$tag"
```

发布流程仍需通过双副本可复现门禁和 `ram-test-release` Environment 审批。仓库必须先启用 GitHub
Immutable Releases，并配置仅限此仓库、具备 Administration(read) 的 Actions Secret
`IMMUTABLE_RELEASES_READ_TOKEN`；发布 preflight 会在任何构建开始前调用官方 API 并 fail closed，
发布后还会验证 `immutable=true`、六个资产名称集合完全一致、状态均为 `uploaded` 且大小有效。最终归档名包含版本，
例如 `NexaWrt-AX9000-nss-v0.1.0-rc.1-verified-dist.tar.gz`，并附带 SHA-256、SBOM 与 GitHub
provenance。所有 RC 都是 prerelease 且不会被标记为 Latest。完整规则与失败恢复步骤见
[版本化发布说明](docs/RELEASES.md)。

GitHub Pages 站点由仓库内 `site/` 提供，地址为
<https://tifycloud.github.io/NexaWrt/>。`devices/xiaomi-ax9000/device.json` 是当前设备能力、flavor、
频道、文档入口和硬件批准状态的单一事实来源；构建、发布、Pages 数据生成和前端展示都会严格复验它。
目录当前只能声明 `hardware_status=unverified`、`production_ready=false`，并且只允许 RAM 启动，
`factory`/`sysupgrade` 必须保持关闭。真机证据未通过前，任何把 AX9000 标成已验证或生产可用的改动都会使策略测试失败。

Pages 门禁从 `refs/heads/main` 做 `fetch-depth: 0` 的完整 checkout，并把该 checkout 作为信任根。
候选 Release 必须是 `immutable=true` 的 prerelease；其发布 tag 必须是直接指向 commit 的轻量 tag，
且该 commit 必须是当前受信任 `main` 的祖先。门禁按 Release asset ID 下载并校验精确六个资产：带版本的
verified-dist archive、对应的外部 `.sha256`，以及 `archive`、`checksums`、`firmware`、`sbom` 四个
provenance bundle。任何额外、缺失、重复、非 `uploaded`、大小无效或内容不匹配的资产都会使整个
Release 被排除。验证器先只下载 archive 与其 provenance 并立即鉴权，通过后才下载其余四个资产；
每个 flavor 最多验证 12 个最新候选，单次运行还有 768 MiB 总下载预算和 30 分钟作业上限。

下载后，外部 `.sha256` 必须精确绑定 archive；archive 内的 `SHA256SUMS` 还必须分别绑定其中的
AX9000 initramfs firmware 与 CycloneDX SBOM。随后四个 provenance bundle 分别验证 archive、归档内
`SHA256SUMS`、firmware 和 SBOM，并同时约束仓库为 `tifycloud/NexaWrt`、签名工作流为
`.github/workflows/release.yml`、source ref 为当前 `refs/tags/<tag>`、source digest 为该轻量 tag 指向的
`main` 祖先提交，并拒绝 self-hosted runner，只接受 GitHub-hosted runner 产生的证明。所有检查通过后，
`scripts/verify-pages-releases.py` 才生成严格 proof manifest；`scripts/generate-pages-data.py` 必须消费
匹配 Release ID 的 proof 才会把下载项写入页面索引。因此，即使有人手工创建名称和六资产外观都相同的
immutable/prerelease lookalike，只要缺少上述可信来源与摘要证明，也会从网站中排除。

x86_64 VM 下载区使用独立门禁：候选必须是 immutable prerelease。验证器兼容历史
`vm-x86_64/v1` 的精确 9 资产、15-key 标签、23-key 报告与两份 provenance；新 `vm-x86_64/v2`
则必须具有精确 21 个资产、18-key `artifact-labels.env`、33-key `smoke-report.txt` 与六份 provenance。
v2 报告必须绑定 raw BIOS、BIOS/EFI Live ISO、BIOS/EFI VMDK 五个实际发布文件，并证明五种镜像都在
对应 SeaBIOS/OVMF QEMU 路径得到 `runtime-pass`，同时证明 LuCI HTTP、VM-only 串口标签、Dropbear
`disabled`/未运行、`authorized_keys` 缺失以及 guest 22 转发端口无 SSH 服务；`esxi_validation`
必须保持 `not-tested`。五个镜像和 `SHA256SUMS` 必须分别具有受信任工作流 attestation；proof 还要为
全部 21 个资产绑定同一 Release 的 asset ID、name、size 与实际 SHA-256，Pages 生成器再与 GitHub
Release API 数据逐项匹配。任一 VM 证据不符，VM 下载即 fail-closed；AX9000 和 VM 两个区域相互隔离，
某一区域无效不会自动禁用另一区域。

站点会在 `main` 更新、发布工作流成功后以及每 6 小时周期复验并重新部署。Official 与 NSS 分频道，
Release 尚不存在或证明失败时页面会明确显示不可下载。站点当前生成 schema-v4 索引，并兼容已有
schema-v3 与历史 `vm-x86_64/v1` 数据；AX9000 区继续提供浏览器云编译、恢复与
测试文档的固定链接，并提供只生成易失性 RAM 会话 UCI 配置片段的生成器。前端对异常设备元数据、异常
URL、历史顺序、重复 tag、`latest` 不一致或非 RAM-only 状态全部 fail-closed。**当前目录仍仅支持
Xiaomi AX9000 的 RAM-only 候选，硬件状态为未验证，绝非生产可用或可刷写固件。**网站不是刷机工具，
也不会把配置烘焙进镜像。


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
manifests/               OpenWrt/feeds/layout、NSS 与 VM ImageBuilder 来源锁定信息
patches/                 RAM-only 安全补丁（含只读 uboot-envtools patch 003）
scripts/backup-router.sh               只读备份
scripts/nss-diagnostics.sh             NSS/ECM 只读运行时诊断
scripts/prepare.sh                     获取、锁定并校验上游
scripts/build.sh                       Linux 干净构建
scripts/build-vm-image.sh              构建 VM smoke 或 x86_64 用户发行镜像
scripts/test-vm-smoke.sh               CI 专用 QEMU 启动、网络、SSH 与 LuCI 冒烟测试
scripts/test-vm-release.sh             对无注入密钥的精确 x86_64 Release 镜像做 QEMU/LuCI 检查
devices/xiaomi-ax9000/device.json      AX9000 RAM-only 设备目录单一事实来源
scripts/device_metadata.py              严格设备目录与构建请求校验器
scripts/verify-pages-releases.py         验证 Release 来源、资产、摘要与 provenance 并生成 proof manifest
scripts/generate-pages-data.py           生成 schema-v3 AX9000/VM 严格白名单 Pages Release 索引
site/                                    GitHub Pages 下载与安全配置站点
scripts/check-kernel-build-identity.sh Kconfig 构建身份与带产品前缀的 source-lock revision 门禁
tests/test_openwrt_defconfig_version.sh 锁定 OpenWrt Kconfig defconfig 保留测试
scripts/collect-build-evidence.sh      构建输入、环境与日志证据
scripts/compare-reproducible-builds.sh 双构建可复现性门禁
scripts/create-hardware-session.sh     创建严格真机测试会话与临时 U-Boot 命令
scripts/ax9000-runtime-probe.sh        真机 RAM-only/flavor 运行时探针
scripts/collect-runtime-evidence.sh    从 RAM 系统安全采集运行时证据
scripts/collect-production-state.sh    重启前后只读采集生产系统状态
scripts/run-ax9000-stress-gate.sh      至少 24 小时双向吞吐/温度/内核压力门禁
scripts/verify-post-reboot-state.sh    生产系统恢复状态原始对比
scripts/verify-stress-evidence.sh      压力测试结构化证据复验
scripts/verify-hardware-evidence.sh    精确产物绑定的真机证据与独立签名门禁
scripts/validate.sh                    静态、源码和产物门检
tests/                                 fail-closed 策略回归测试
.github/workflows/                      PR 构建与受保护 prerelease
```
