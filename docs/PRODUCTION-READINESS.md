# AX9000 生产就绪门禁

本文定义 NexaWrt AX9000 候选从“可构建”到“允许生产使用”必须满足的证据链。**当前产物始终是
initramfs RAM-only 候选，不是刷机包。** 在全部真机门禁和独立签名完成前，不得加载；即使门禁
全部通过，也只批准本次镜像的 RAM 启动，不批准 `sysupgrade`、factory、UBI 写入或任何持久安装。

## 1. 自动化与可复现构建门禁

每次提交至少运行：

```sh
./tests/test_static.sh
```

发布候选还必须经过两个相互独立、无共享构建目录的干净构建，并由
`scripts/compare-reproducible-builds.sh` 比较精确 ITB、包清单、配置、buildinfo、输入摘要和规范化
SBOM。真机会话只接受该脚本生成且能再次通过 `--verify-verified-dist` 的 verified dist；手工复制 firmware
并添加 `flavor=nss` 等自述文件不构成候选。`REPRODUCIBILITY.json` 使用严格 schema 4，必须声明
`reproducible=true`，绑定恰好两个独立 input build 的 checksum receipt 及 evidence receipt 摘要，并把
comparison receipt、flavor、ITB 文件名/SHA-256/字节数和仓库输入摘要一起纳入校验。左右 checksum
receipt 及 evidence receipt 的摘要都必须互不相同；每个构建还必须提供受 checksum/evidence receipt 双重
绑定的 `BUILD-IDENTITY.txt`，分别声明 `replica_id=a|b`，并绑定同一个 run id/attempt、project commit 与
source commit。发布 workflow 还必须在各 matrix build job 上传副本后生成 canonical `producer-descriptor.json`；descriptor 精确绑定
repository、signer workflow、run ID/attempt、flavor、replica、Artifact API 返回的 artifact ID/name，以及该副本
`SHA256SUMS` 的文件名和 SHA-256。GitHub build-provenance attestation 的 subject 是 descriptor 本身，而不是可被
重新贴标签的 receipt。compare job 离线验证两份 descriptor attestation 后，才派生
`github-artifact:<id>:bundle-sha256:<digest>` 并写入 schema 4 的两个 `producer_id`；descriptor 与 bundle 分别固化为
`REPRODUCIBILITY/{left,right}.producer-descriptor.json` 和 `{left,right}.provenance.bundle.json`。
`--verify-verified-dist` 使用显式绝对路径的 GitHub CLI，并先校验该可执行文件的预期 SHA-256，再对嵌入 descriptor、
bundle、固定仓库 `tifycloud/NexaWrt` 和固定 signer workflow 离线验签。GitHub Actions 环境缺失、
相同或未验证的 producer identity 均拒绝；本地 compare 只会标记为 `local-unattested:a|b`，这种输出可用于
开发预检，但最终硬件门禁明确拒绝。直接复制同一个构建目录或伪造不同路径冒充双构建会被拒绝。目录中的真实 ITB、
`SHA256SUMS`、两个 receipt 或任一受比较文件发生变化都会 fail closed；`EVIDENCE.sha256`
还必须精确列出并校验全部六个 evidence payload，不能只是一个未验证的占位文件。

验证器还严格解析 `BUILD-MANIFEST.txt`、`EVIDENCE/SOURCE-STATE.txt` 和 `EVIDENCE/INPUTS.sha256`：
`source_repository`/`source_commit` 必须与当前仓库的 `manifests/upstream.lock` 或 `manifests/nss.lock`
一致；每个 flavor 预期 feed 的 repository/commit/已审阅 patch digest 必须与 `manifests/feeds.lock`、
对应 source-state 以及当前仓库 patch 文件逐字节一致。`INPUTS.sha256` 必须精确覆盖构建 Makefile、
prepare/build/validate/evidence/reproducibility 策略脚本、共享 Git 环境净化器、内核身份检查器、flavor config、
overlay `files*`、全部锁文件、整个 patch 树、两个 GitHub workflow，以及 session/production/runtime/stress/
post-reboot/final hardware verifier 全部生产策略脚本，并包含 NSS 产物复制的 `THIRD_PARTY_NOTICES.md`；枚举逻辑由
`scripts/list-build-inputs.sh` 在生成端与验证端共享，缺少脚本/config/overlay/notice、额外输入、摘要漂移或符号链接
均拒绝。两个 input build 的 `project_tree_state` 必须为 `clean`，且 `project_commit` 必须精确等于运行
验证器时仓库的 `HEAD`；旧提交候选或带未提交输入的候选均拒绝。缺失、额外、重复、近似 pin 或目录内
自洽伪造都拒绝。
OpenWrt 的 `include/kernel.mk` 会用解析后的 Kconfig 覆盖环境值，因此两个 seed config 以及
解析后的 source `.config` 都必须精确包含：

```text
CONFIG_KERNEL_BUILD_USER="nexawrt"
CONFIG_KERNEL_BUILD_DOMAIN="builder"
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
```

firmware-visible `CONFIG_VERSION_CODE` 必须按当前 flavor 自己的 source lock 派生：

```text
official: CONFIG_VERSION_CODE="nexawrt-r0-f0a60eee"  # manifests/upstream.lock OPENWRT_COMMIT 前 8 位
nss:      CONFIG_VERSION_CODE="nexawrt-r0-d6848fa2"  # manifests/nss.lock NSS_OPENWRT_COMMIT 前 8 位
```

使用小写 `nexawrt-` 产品前缀，使显式值不会等于 OpenWrt 根据 `git %h` 生成的动态默认值，并保持为
适合 firmware/package version 的保守 token；OpenWrt 只有在 `CONFIG_IMAGEOPT=y` 时才让
`CONFIG_VERSIONOPT` 可见，因此两者都必须显式启用，才能让 `VERSION_CODE` 经过 `make defconfig` 后保留。不得依赖 shallow clone 产生的 7 位或其他动态唯一缩写。
任何空值、前缀丢失、缩写长度变化、跨 flavor revision 或 seed/对应 source lock 漂移都必须 fail closed。

干净构建不应把 source 网络可用性误当成供应链信任条件：若现有 worktree 的 raw
`remote.origin.url` 恰好一个且精确为当前 canonical source URL、完全没有
`remote.origin.pushurl`，并且本地完整存在 exact `SOURCE_COMMIT` commit checkout closure，
`scripts/prepare.sh` 可以离线复用该对象；它仍必须 checkout/reset exact commit、`git clean`、应用仓库
patch，并通过既有 HEAD/origin/source validation。错误或额外 fetch URL、任意 pushurl、缺失对象、
非 commit 对象、以及仅有错误 HEAD 均不能冒充命中；没有 exact commit 时继续执行原有网络 fetch 重试。

已经完成 exact feed prepare 的 worktree 只有在**整个安装状态**可证明时才可离线复用：全部 expected
feed checkout 必须是 lock 的 exact HEAD、同样满足唯一 raw canonical origin 且无 pushurl、在禁用 lazy
fetch/replace 后具有完整 commit/tree/blob closure、不使用 sparse checkout/index、assume-unchanged 或
skip-worktree，且没有 staged、untracked、ignored 或未审阅修改；NSS packages 只允许 exact reviewed
source-archive patch。`feeds/` 顶层集合、`package/feeds/` exact feed 集合以及每个 package symlink 的
checkout containment 也必须全部通过。任一条件失败即删除现有 feed 状态，保持原有逐 feed exact
fetch/shallow fallback；成功复用仍复制 seed、运行 `make defconfig`、删除生成 metadata，并完成全部最终
HEAD/origin/clean/link validation。该优化不允许 feed pin fallback 或近似 revision。

所有会调用 Git 的构建、校验、证据、产物 staging 与可复现性入口都先加载
`scripts/sanitize-git-environment.sh`。它清除 `GIT_DIR`/`GIT_WORK_TREE`/对象库/index/namespace、任意
`GIT_CONFIG_*` 注入、全局/系统 config、exec path 和 template 重定向，并强制禁用 replace 与交互式凭据提示；
`prepare.sh` 随后只显式加入受控 HTTP proxy。这样调用者的 ambient Git 环境不能把 `git -C` 偷换到另一仓库，
也不能用 global hook、`url.*.insteadOf` 或编号 config 参数改变锁定获取行为。

`scripts/build.sh` 仍防御性导出匹配值：

```text
KBUILD_BUILD_USER=nexawrt
KBUILD_BUILD_HOST=builder
KBUILD_BUILD_VERSION=0
```

前两个 export 只保护直接或辅助 kernel make 路径，不能替代上述 Kconfig 锁；第三个避免 build
version 自动递增。`scripts/check-kernel-build-identity.sh`、`scripts/validate.sh` 和
`tests/test_kernel_build_identity_policy.sh` 共同拒绝缺失、重复、空值、7 位 revision 和 stale lock。
`tests/test_openwrt_defconfig_version.sh nss` 还会在 `/tmp` 获取锁定的 disposable NSS source，构建该
source 的真实 OpenWrt Kconfig `conf`，并用与顶层 `make defconfig` 相同的 recipe 确认
`CONFIG_IMAGEOPT=y`、`CONFIG_VERSIONOPT=y` 与带产品前缀的 `CONFIG_VERSION_CODE` 都被保留。

构建日志归档前执行凭据扫描。GitHub token 前缀匹配保持**大小写敏感**：真实的小写 `gh*` /
`github_pat` 形式必须拒绝；大写 `GHS_` 等编译器测试向量不应误报。私钥标记仍一律拒绝。不要在
日志、配置、提交或 issue 中放入真实凭据。

## 2. GitHub 仓库管理员设置

- `main` 启用 branch protection，要求构建、策略和可复现性检查通过；
- `ram-test-release` Environment 只允许受信任维护者审批；
- tag 只允许 `ram-test-v*`（official）和 `ram-test-nss-v*`（nss）；
- 发布保持 prerelease；publish job 必须先严格复验下载的 `verified-dist`，且不得向该目录追加或复制文件。
  完整目录只在外部 `release-staging/publish` 打成确定性 `tar.gz` 并生成校验，解包后再次严格复验；
  provenance bundle 也只放入 `publish`，Release 上传该目录的全部文件；
- 不上传 sysupgrade、factory、UBI、rootfs 或其他可持久写入镜像。

## 3. 创建不可拼接的真机会话

每次冷启动测试必须使用新的、权限受控且**完全为空**的证据目录和新的会话。先准备已通过双构建比较的
verified dist，再运行：

```sh
EVIDENCE="$PWD/hardware-evidence/ax9000-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$EVIDENCE"
./scripts/create-hardware-session.sh "$EVIDENCE" <verified-dist>
```

脚本以 `O_CREAT|O_EXCL|O_NOFOLLOW` 原子创建权限为 `0600` 的 `SESSION.txt`；目录非空、已有会话、
叶子/目录路径符号链接或中途写入失败都会拒绝并清理本次新文件，绝不轮换或覆盖既有证据。严格格式只有一行：

```text
session_id=<64 位小写十六进制>
```

脚本同时以相同独占语义创建权限为 `0600` 的 `CANDIDATE.txt`，并对文件与目录执行 `fsync`。它是
verified dist 的受控 receipt，严格字段集为：

```text
schema=1
flavor=official|nss
firmware_filename=<精确 ITB basename>
firmware_sha256=<真实 ITB SHA-256>
firmware_size=<真实 ITB 十进制字节数>
verified_dist_sha256sums_sha256=<verified dist/SHA256SUMS 的 SHA-256>
reproducibility_sha256=<REPRODUCIBILITY.json 的 SHA-256>
build_manifest_sha256=<BUILD-MANIFEST.txt 的 SHA-256>
repository_inputs_sha256=<source/feed locks、reviewed patches 与双构建完整 feed 工作树状态的规范 receipt SHA-256>
comparison_receipt_sha256=<两个 input build receipts 的规范比较 receipt SHA-256>
```

`collect-production-state.sh`、`collect-runtime-evidence.sh`、压力门禁和最终硬件证据验证都要求同一
`SESSION.txt`；最终验证还要求 `CANDIDATE.txt` 与重新验证 verified dist 得到的 metadata 逐字节相同。
缺失、重复字段、大写、长度错误、符号链接、目录外路径或 receipt 漂移均 fail-closed。

## 4. U-Boot 冷启动测量

### 4.1 禁止持久修改

所有 U-Boot 操作必须是当前上电周期的临时变量。**绝对禁止执行 `saveenv`，禁止擦除、写入、
格式化、升级、修改 bootcmd 或保存 bootargs。** 测试结束通过重启/断电返回当前生产系统。

TFTP 将候选加载到 `${loadaddr}` 后，按 `create-hardware-session.sh` 输出的本次会话命令执行：临时向
`bootargs` 追加且仅追加一个 `nexawrt.session=<session_id>`。哈希必须由下面这个单行条件命令执行，
使成功标记只能来自 `hash sha256 ${loadaddr} ${filesize} nexawrt_image_sha256` 的零退出状态：

```text
if hash sha256 ${loadaddr} ${filesize} nexawrt_image_sha256; then echo NEXAWRT_HASH_EXECUTION=success; else echo NEXAWRT_HASH_EXECUTION=failure; fi
```

随后才可设置 size、`printenv` 四个值并执行 `bootm ${loadaddr}`。不得手工抄写预期 SHA 或单独
`echo` 成功标记冒充测量结果。

### 4.2 UART 严格字段

完整、连续的 `uart-cold-boot.log` 必须保留未换行的 U-Boot prompt 与上述完整条件命令，并在其后
各恰好一次包含以下独立输出行；不得出现 failure 行：

```text
<U-Boot prompt> if hash sha256 ${loadaddr} ${filesize} nexawrt_image_sha256; then echo NEXAWRT_HASH_EXECUTION=success; else echo NEXAWRT_HASH_EXECUTION=failure; fi
NEXAWRT_HASH_EXECUTION=success
nexawrt_image_sha256=<U-Boot 对实际已加载内存计算出的 64 位 SHA-256>
nexawrt_image_size_hex=<U-Boot ${filesize} 的十六进制值，不带 0x>
nexawrt_session_id=<SESSION.txt 中的 64 位小写十六进制>
ethaddr=<U-Boot 实际 printenv 输出的 MAC 地址>
```

最终验证器要求 exact hash 命令、success 和测量字段的因果顺序，拒绝只有结果变量、单独伪造
success、错误 hash 参数/目标变量、failure 或重复命令。它把 SHA 和十六进制 size 与 verified dist
中的实际 ITB 比较，把 session 与 `SESSION.txt`/运行时/压力证据比较，并把 UART `ethaddr` 与生产
系统 `fw_printenv` 比较。任一值错误、缺失或重复都拒绝，哪怕攻击者重新生成 checksum 或重新提交
审批文件。

## 5. 同一会话与同一设备绑定

运行时探针第五个参数是本次 session。探针要求 `/proc/cmdline`：

- 恰好一个 `root=`，且为 `root=/dev/ram0`；
- 恰好一个 `nexawrt.session=`，且值与 `SESSION.txt` 完全相同；
- 不含 `ubi.mtd=`、`root=/dev/ubiblock*` 等持久 UBI root 选择器。

探针通过 `fw_printenv -n ethaddr` 读取稳定设备身份，转为小写 MAC，并计算：

```text
device_fingerprint_sha256 = sha256("xiaomi,ax9000\nethaddr=<lowercase-mac>\n")
```

两个 flavor 都明确启用经过 `patches/003-uboot-envtools-read-only.patch` 裁剪的
`uboot-envtools`。最终 initramfs **必须保留** `fw_printenv`、`fw_printsys` 和 target-specific
`/etc/uci-defaults/30_uboot-envtools`：该 defaults 脚本只在 RAM/tmpfs 中生成 AX9000
`appsblenv` 的读取定位配置，使 `fw_printenv` 能找到环境区；它不是 U-Boot 环境写入脚本。补丁必须
删除 `fw_setenv`、`fw_setsys`、`fw_loadenv` 与 `/etc/board.d/05_fw_defaults`。源码和最终 rootfs
门禁还会扫描 `30_uboot-envtools`，拒绝其中调用任何环境或 flash 写工具。

AX9000 image profile 的 `DEVICE_PACKAGES` 必须恰好只排除 `-ubi-utils -mtd`，**不得出现
`-uboot-envtools`**。OpenWrt `merge_packages` 会把 profile 中的显式负包作为最终排除项；因此即使
seed config 有 `CONFIG_PACKAGE_uboot-envtools=y`，profile 中的 `-uboot-envtools` 仍会使最终镜像缺少
`fw_printenv`。仓库 patch、准备后的 `SOURCE_DIR` 和最终 rootfs 三层门禁都必须阻止这种回归。

`runtime-gate.txt` 必须严格包含：

```text
fw_printenv_available=yes
uboot_env_write_tools=absent
```

探针只用 `fw_printenv -n ethaddr` 读取设备身份；发现三个写工具中的任意一个都立即失败。

`device.txt` 严格字段为：

```text
model=xiaomi,ax9000
image_sha256=<verified ITB SHA-256>
flavor=official|nss
probe_sha256=<本仓库 ax9000-runtime-probe.sh SHA-256>
session_id=<SESSION.txt 的 session>
device_fingerprint_sha256=<上述 fingerprint>
```

`runtime-gate.txt` 也必须包含相同 `session_id` 和 fingerprint，并只允许当前 flavor 对应的严格
schema。24 小时压力日志和 `stress-gate.txt` 再次携带二者，并绑定同一 `device_boot_id`、首末设备 uptime 与
`execution_mode=production`；每轮 SSH 连续性检查重新读取 cmdline、boot ID、uptime 和 `fw_printenv ethaddr`。生产系统重启前后采集的完整 U-Boot 环境必须一致，其中 `ethaddr` 计算
出的 fingerprint 必须与运行时/压力证据相同。这样不能把不同镜像、不同启动会话或不同路由器的
证据拼接成一次通过记录。

## 6. 必需证据集

最终目录必须由 `SHA256SUMS` 精确覆盖以下 payload，以及审批文件和签名；不得缺项、增项、使用
子目录或符号链接：

```text
SESSION.txt
CANDIDATE.txt
device.txt
uart-cold-boot.log
uboot-help.txt
uboot-printenv-before.txt
uboot-printenv-after.txt
production-cmdline-before.txt
production-cmdline-after.txt
production-capture-before.txt
production-capture-after.txt
mtd-layout-before.txt
mtd-layout-after.txt
production-identity-before.txt
production-identity-after.txt
ram-boot.log
runtime-gate.txt
post-reboot-gate.txt
stress-gate.txt
stress-24h.log
network-regression.log
thermal.log
kernel-health.log
APPROVAL.txt
APPROVAL.txt.sig
SHA256SUMS
```

采集顺序：

```sh
./scripts/collect-production-state.sh <production-ssh> "$EVIDENCE" before
# UART 中断、TFTP、实际内存 hash/size/session/ethaddr 记录、仅 RAM boot
./scripts/collect-runtime-evidence.sh <ram-ssh> <verified-dist> official|nss "$EVIDENCE"
./scripts/run-ax9000-stress-gate.sh <ram-ssh> "$EVIDENCE" <iperf-server> <min-mbps>
# 重启/断电回到原生产系统
./scripts/collect-production-state.sh <production-ssh> "$EVIDENCE" after
./scripts/verify-post-reboot-state.sh "$EVIDENCE"
./scripts/verify-stress-evidence.sh "$EVIDENCE"
```

所有采集器要求既有 `SESSION.txt`。生产 before/after 各只允许一次 SSH 事务：远端一次性打包 cmdline、MTD、
完整 U-Boot environment、生产身份和 schema 2 capture metadata；metadata 绑定随机 256-bit challenge、session、
phase、wall-clock/uptime、boot ID、board/MAC/device fingerprint 以及四个 payload 摘要。本地严格限制 tar 成员、
类型、大小、UTF-8 和摘要，并以 `O_EXCL` 提交，拒绝重采或覆盖。runtime collector 也把 `device.txt`、
`runtime-gate.txt`、`ram-boot.log` 作为一次性事务：任一目标已存在即在 SSH 前拒绝，归档全部验证后才以
`O_EXCL|O_NOFOLLOW` 逐项提交，失败只清理本次新文件；重试必须创建全新 session。其余输出采用安全创建
或同目录临时文件加原子替换；针对 `SESSION.txt`、生产/运行时采集、压力日志和 post-reboot gate 的 leaf
symlink victim 都有回归测试。

## 7. 24 小时与恢复门禁

压力门禁至少运行 86,400 秒并完成至少 24 轮双向网络测试，持续检查 session、设备 fingerprint、
RAM root、无持久 UBI mount、内核 panic/oops、SSH 连续性、吞吐下限、温度和热节流。生产模式忽略调用者
`PATH`，只使用经过所有者/权限检查的固定系统工具路径，并要求设备端 `iperf3` 位于受信任的
`/usr/bin/iperf3`。每轮 network、thermal、kernel-health 记录都绑定相同 round、wall-clock epoch、主机
monotonic timestamp、设备 boot ID 和设备 uptime；验证器要求 boot ID 全程不变、设备 uptime 严格递增并与
主机 monotonic 进度一致，首尾真实覆盖整个压力区间，相邻间隔受限且 wall/monotonic 漂移不超过 300 秒。中断或任何失败只保留 `completed=no`
进度，不生成通过 gate。成功路径先在 `.stress-verify.*` 临时证据目录生成 `completed=yes` 候选并运行完整
verifier，只有通过后才原子替换正式日志，并最后独占提交 `stress-gate.txt`。

重启后必须回到原生产系统；`verify-post-reboot-state.sh` 先验证 before/after 属于同一 session/设备、challenge
不同、boot ID 不同、after epoch 更晚且 capture 摘要与原始 payload 一致，再对比前后生产 cmdline、MTD 布局、
完整 U-Boot 环境和设备身份，并强绑定已记录的生产基线 `root=/dev/ubiblock0_1`。任何 `/dev/ram*`（包括
`ram0`、`ram1`、`ramdisk*`）、其他 root、MTD/env/identity 变化或无法恢复均立即失败；即使错误 root
在 before/after 中相同也不能通过。

最终 `verify-hardware-evidence.sh` 还解析 `ram-boot.log` 中唯一的
`=== hardware session and identity ===` 段，要求其中只有与 `SESSION.txt`、生产 `ethaddr` 及计算所得
fingerprint 完全一致的三行。重复完整日志、追加第二组 identity 或跨设备/跨会话拼接均 fail-closed。

## 8. 独立审批

独立审核人只在复核原始 UART、生产前后状态、运行时、24 小时日志、verified dist 和 checksum 后，
签署严格字段集的 `APPROVAL.txt`：

```text
decision=approved-for-ram-boot-only
reviewer=<allowed_signers identity>
reviewed_utc=<UTC RFC3339>
evidence_sha256=<按固定 payload 顺序计算的摘要>
candidate_schema=1
flavor=official|nss
firmware_filename=<精确 ITB basename>
firmware_sha256=<精确 ITB SHA-256>
firmware_size=<精确 ITB 十进制字节数>
verified_dist_sha256sums_sha256=<verified dist/SHA256SUMS 的 SHA-256>
reproducibility_sha256=<REPRODUCIBILITY.json 的 SHA-256>
build_manifest_sha256=<BUILD-MANIFEST.txt 的 SHA-256>
repository_inputs_sha256=<仓库锁定输入 receipt SHA-256>
comparison_receipt_sha256=<双构建 comparison receipt SHA-256>
```

除 reviewer、时间和 evidence 摘要外，所有 candidate 字段都必须与 `CANDIDATE.txt` 完全相同；签名因而
覆盖精确 artifact、双构建 receipts、source/feed locks、reviewed patches、完整 feed 工作树状态以及三个受控文件摘要。使用 SSH
signature namespace `nexawrt-hardware-approval` 签名。缺失 receipt 绑定、重复/额外字段、错误镜像/证据
摘要、不受信任签名、未来时间或超过 30 天均拒绝；最大有效期只能缩短，不能延长。

真机现场复验不需要在线访问 GitHub，但可信工作站必须提供管理员固定的 GitHub CLI 绝对路径及其预期
SHA-256；验证器不会从通用 `PATH` 搜索替代程序。候选必须在 `REPRODUCIBILITY.json` 中绑定两个不同的
GitHub artifact ID/name、两份不同 descriptor/bundle 摘要，以及嵌入的
`REPRODUCIBILITY/{left,right}.producer-descriptor.json` 和 `{left,right}.provenance.bundle.json`。最终验证器先校验
GitHub CLI 文件摘要，再用固定仓库与 signer workflow 对两份 descriptor bundle 离线验签；descriptor/bundle
缺失、artifact 重标、摘要漂移、签名/仓库/workflow/subject 不匹配或 verifier 路径/摘要缺失均 fail-closed。本地 `local-unattested:*` 候选不含这些 bundle，只能做开发预检，不能进入最终硬件签名。发布时附带的 firmware/SBOM/checksum/archive provenance bundle 是额外的
分发层证明，不替代副本生产者身份。威胁模型不覆盖持有受信 reviewer 私钥的
本地攻击者；私钥保护、allowed-signers 管理与 CI environment 审批仍必须独立执行。

最终复验：

```sh
export NEXAWRT_ATTESTATION_VERIFIER=/absolute/admin-managed/path/to/gh
export NEXAWRT_ATTESTATION_VERIFIER_SHA256=<预先登记的 gh SHA-256>
./scripts/verify-hardware-evidence.sh "$EVIDENCE" <verified-dist> <allowed-signers>
```

通过信息仍只表示：**该精确镜像、该会话、该设备的 RAM boot 证据被批准。**

## 9. 始终关闭的路径

以下路径在当前阶段没有任何例外：

- `saveenv`、`fw_setenv`、`fw_setsys`、`fw_loadenv`、`mtd`、`nandwrite`、`ubiformat`、`ubiupdatevol`；
- 在 AX9000 profile 中加入 `-uboot-envtools`，导致 `merge_packages` 移除只读工具；
- 删除或禁用只读定位所需的 `30_uboot-envtools`，或把它替换为调用 set/write 工具的脚本；
- `sysupgrade`、factory image、安装器、持久 rootfs/overlay；
- 根据“参考项目可刷”“跑过一次”或“速度更快”绕过恢复、24 小时或签名门禁；
- 将 RAM-only 通过等同于可刷写或生产持久安装批准。

缺少真实 AX9000、UART、可靠恢复路径或完整 24 小时测试时，状态必须保持 **未批准、禁止加载、
禁止刷写**。
