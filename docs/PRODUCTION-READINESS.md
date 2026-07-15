# AX9000 生产就绪门禁

NexaWrt 当前只发布 **initramfs RAM 启动候选**。`production-ready` 在本项目中不等于“可以刷写”：
只有完整构建、双构建可复现、供应链证明、UART/恢复、真机回归和压力测试全部通过后，某个**精确 SHA-256 的 ITB**才可以被批准用于 RAM 启动。持久化安装继续保持关闭。

## 1. 自动化门禁

代码合并前必须通过：

```sh
./tests/test_static.sh
```

它覆盖：

- official/NSS 完整 commit 和 feed 锁；
- NSS Codelinaro 源码归档完整 commit + SHA-256；
- 补丁可审计性、RAM root、全部持久 MTD 分区内核只读和危险包排除；
- `sysupgrade -F` 的不可强制返回码 74；
- initramfs 中 `sysupgrade`、`factoryreset`、`firstboot`、`jffs2reset`、`jffs2mark`、`mount_root` 运行时拒绝器；
- 精确单一 ITB allowlist、强制 package manifest、CycloneDX SBOM、构建日志和环境证据；
- SHA-256 自校验、双 runner 可复现性比较和 GitHub workflow 最小权限。

发布 tag `ram-test-v*` 会执行两个互不共享下载缓存的干净构建。只有固件、包清单、解析后的配置、feed/buildinfo、输入摘要及规范化 SBOM 全部一致，才会产生 `verified-dist`。发布 job 不运行构建脚本，只下载已比较的 payload，生成 GitHub Artifact Attestations，并创建 prerelease。

## 2. GitHub 仓库管理员设置

YAML 不能自动创建仓库保护规则。管理员必须手工完成：

1. 创建 Environment：`ram-test-release`；
2. 添加 required reviewer，启用 prevent self-review；
3. Environment deployment branches/tags 只允许受保护的 `ram-test-v*`；
4. 创建 tag ruleset，禁止未授权创建、更新和删除 `ram-test-v*`；发布 tag 必须是直接指向 commit 的轻量 tag，workflow 会拒绝 annotated tag；
5. `main` 启用 pull request、required checks 和禁止 force-push；
6. 启用 immutable releases（若仓库设置提供）；
7. 不添加长期发布私钥；attestation 使用 GitHub OIDC；
8. 立即撤销任何曾出现在聊天、日志或终端历史中的 GitHub PAT。

未完成上述设置时，不得把自动发布称为受保护发布。

## 3. 构建产物要求

每个候选目录至少包含：

- 精确 AX9000 `single_ubi` initramfs ITB；
- OpenWrt package `.manifest`；
- CycloneDX `.bom.cdx.json`；
- `config.buildinfo`、`feeds.buildinfo`、`profiles.json`、`version.buildinfo`；
- `BUILD-MANIFEST.txt`、`DO-NOT-FLASH.txt`；
- `EVIDENCE/` 下的构建日志、resolved config、输入摘要、源码/feed 状态和构建环境；
- `SHA256SUMS`；
- 发布时额外包含 `REPRODUCIBILITY.json` 和三份离线 attestation bundle。

任何额外 `.bin/.img/.itb/.ubi/.ubifs/.dtb/.elf` 等镜像类文件都会使 staging 失败。

## 4. 真机门禁

真机操作前先完成 `docs/RECOVERY.md` 与 `docs/TESTING.md`。不要猜测 U-Boot RAM 地址，也不要执行 `saveenv`、NAND/MTD/UBI 写命令。

证据目录必须包含：

```text
device.txt
uart-cold-boot.log
uboot-help.txt
uboot-printenv-before.txt
uboot-printenv-after.txt
ram-boot.log
runtime-gate.txt
post-reboot-gate.txt
stress-gate.txt
stress-24h.log
network-regression.log
thermal.log
APPROVAL.txt
SHA256SUMS
```

`device.txt`：

```text
model=xiaomi,ax9000
image_sha256=<精确 ITB SHA-256>
```

`runtime-gate.txt`：

```text
root=/dev/ram0
persistent_ubi_attached=no
persistent_mounts=no
all_mtd_partitions_readonly=yes
raw_mtd_write_probe=blocked
sysupgrade_guard_exit=74
factoryreset_guard_exit=74
firstboot_guard_exit=74
jffs2reset_guard_exit=74
jffs2mark_guard_exit=74
mount_root_guard_exit=74
```

`post-reboot-gate.txt`：

```text
reboot_to_production=pass
mtd_layout_unchanged=pass
uboot_env_unchanged=pass
```

`stress-gate.txt`：

```text
stress_24h=pass
network_regression=pass
panic_oops=none
thermal_throttle=none
```

审批文件只允许 RAM 启动，并必须绑定精确固件与原始证据摘要：

```text
decision=approved-for-ram-boot-only
reviewer=<allowed_signers 中的身份>
reviewed_utc=YYYY-MM-DDTHH:MM:SSZ
firmware_sha256=<精确 ITB SHA-256>
evidence_sha256=<脚本定义的证据 payload 摘要>
```

独立审核者使用 OpenSSH 签名命名空间 `nexawrt-hardware-approval` 对 `APPROVAL.txt` 生成
`APPROVAL.txt.sig`。可信公钥使用 OpenSSH `allowed_signers` 格式保存在证据目录之外；提交者
自行填写 reviewer、修改日志或重算 SHA256SUMS 都不能替代审核者签名。默认只接受 30 天内、
不超过当前时间 5 分钟的审批；可通过受控环境变量缩短有效期，不应放宽。

验证：

```sh
./scripts/verify-hardware-evidence.sh \
  /path/to/hardware-evidence \
  /path/to/verified-dist \
  /secure/path/to/trusted-reviewers.allowed_signers
```

脚本通过只说明签名审核者批准了与精确 ITB 绑定的证据 payload，且目录满足机器可检查的最低
门槛；它不替代串口日志人工审核、恢复演练、真实 raw-MTD 负向探测或 NAND/OOB/ECC 专业恢复能力。

## 5. 仍然关闭的生产路径

以下条件任一未满足，都不得设计或发布持久化镜像：

- 有同布局备用机完成真实写回恢复；
- 明确 U-Boot/SMEM/DTS/`/proc/mtd`/UBI 的边界一致性；
- 已验证 NAND bad block、ECC/OOB 和断电恢复；
- 已验证旧运行系统发起升级时也不会绕过目标镜像保护；
- 已设计 A/B 或等价原子回退，并完成故障注入；
- official 与 NSS 都完成至少 24 小时压力、温度、吞吐、延迟、防火墙/VLAN 和重启回归；
- 有独立审核者批准精确源码 commit、artifact SHA 和恢复证据。

在此之前，本项目的“生产使用”最多是受控实验室/维护窗口中的 RAM 启动，不是日常持久固件。
