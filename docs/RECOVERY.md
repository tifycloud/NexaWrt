# NexaWrt：Xiaomi AX9000 恢复与安全边界

本文只适用于 **NexaWrt 当前支持的 Xiaomi AX9000**，且仅适用于已经现场确认的
**single-large-UBI v1** 布局。NexaWrt 当前仅提供 initramfs RAM-test 候选路径，不授权
持久化安装；其他设备或布局必须另行适配和验证，本文不构成未来支持承诺。当前尚未完成
真机 RAM 启动批准。

> [!IMPORTANT]
> 当前未发现这台设备已有可用备份。没有“以后再补备份”的安全余量：在验证 UART、
> U-Boot 和 initramfs RAM 启动之前，禁止写入、擦除、升级或调整任何闪存内容。
> NexaWrt 当前阶段只允许 initramfs RAM 测试。

## 已知现场布局

必须从当前生产系统再次读取并核对，而不是只依赖本文：

| 项目 | 预期值 |
| --- | --- |
| `rootfs` MTD 大小 | `0x0e800000`（232 MiB） |
| UBI volume 0 | `kernel` |
| UBI volume 1 | `rootfs` |
| UBI volume 2 | `rootfs_data` |
| 小米原厂/当前生产布局基线 root 参数 | `root=/dev/ubiblock0_1` |
| NexaWrt initramfs RAM-test 预期 root 参数 | `root=/dev/ram0` |
| NexaWrt RAM-test 持久 UBI 状态 | 未附加、未挂载、未写入 |

表中的 volume 编号、名称和 `root=/dev/ubiblock0_1` 只描述小米原厂/当前生产系统基线。
NexaWrt RAM-test 的 `/proc/cmdline` 必须使用 `root=/dev/ram0`，不得出现 `ubi.mtd=` 或
`/dev/ubiblock`，并且 `/sys/class/ubi` 下不得出现自动附加的持久 UBI 设备。若 MTD 大小或
上述 RAM-test 条件有任一差异，立即停止。不同布局之间不能共享恢复命令或镜像。

这里的 `0x0e800000` 来自此前对当前设备的只读检查；它比把 OpenWrt 官方 AX9000 DTS 中
原 `ubi_kernel` 与 `rootfs` 区间直接合并得到的 `0x0ee80000` 少约 6.5 MiB。真实设备重新读取
前不得扩大边界，也不得把两种布局混用。

## U-Boot 可见范围是任何持久化研究的硬阻断项

Linux DTS 中的 MTD 定义不能证明 bootloader 使用同一边界。任何持久化研究开始前，必须通过 UART
只读确认 U-Boot 的 `mtdparts`、`bootcmd`、启动变量和 UBI 扫描范围，并确认其能覆盖整个
`rootfs` MTD。只检查当前 `kernel` volume 恰好能启动并不充分：UBI 的磨损均衡可能在以后
把启动数据移动到其他物理擦除块。若 U-Boot 只能看到旧分区的一部分，设备可能在后续重启
时失去启动能力。

这一检查不得包含 `saveenv`、`nand write`、`ubi write`、擦除或格式化。若 U-Boot 命令语义
不明确，应停在 `help`、`printenv` 和日志采集，不要猜测执行。未证明 bootloader 与 Linux
边界一致前，sysupgrade 始终禁止。

## 恢复准备的最低要求

在任何真机 initramfs RAM 启动获得批准前应具备：

- 稳定的 3.3 V UART 连接，已经确认 TX/RX/GND，**不得接入 5 V**；
- 完整保存的一次当前生产固件冷启动串口日志；
- 已验证能够在不修改环境的情况下中断 U-Boot 并返回当前启动；
- 已记录 U-Boot 中可用的网络加载命令、RAM 地址限制和启动命令；
- 已确认候选命令行是 `root=/dev/ram0`，且不含 `ubi.mtd=` 或 `/dev/ubiblock`；
- 已确认启动流程不会自动附加、挂载或写入持久 UBI；
- 已运行 `scripts/backup-router.sh`，关键 MTD 均有完整本地镜像和 SHA-256；
- 至少一份备份已复制到与开发机不同的可靠介质；
- 已明确恢复到当前启动的操作步骤，并能在串口上执行。

仅仅“能看到串口输出”不等于具备恢复能力。必须确认输入可靠、能够中断倒计时，并能
在不保存环境的情况下继续当前启动。完成这些准备仍不等于获得真机 RAM 启动批准。

## 只读信息与备份

推荐从当前生产系统运行：

```sh
./scripts/backup-router.sh
```

脚本默认使用 `root@192.168.2.1`，通过 SSH key 或 SSH 自身的交互认证登录。不要把
密码放在命令行、环境变量、脚本、配置文件或备份目录中，也不要使用 `sshpass`。

必须备份并核对：

- `/proc/mtd`
- `ubinfo -a`（若系统提供 `ubinfo`）
- `dmesg`
- `fw_printenv` 输出（若工具和配置可用）
- `appsblenv`、`appsbl`、`appsbl_1`、`art`、`bdata`、`bootconfig`、
  `bootconfig1`、`rootfs` 原始 MTD
- 本地生成的 `SHA256SUMS`

不要默认额外导出 `/etc/config`、`/etc/shadow`、Dropbear/OpenSSH 私钥、无线密码或
其他明确敏感配置。注意：要求备份的原始 `rootfs` MTD 覆盖整个 UBI 区域，其中可能
包含 `rootfs_data`，因此它本身仍可能含有敏感信息。备份目录必须按敏感材料保护，
不得提交 Git。备份脚本成功只代表关键基线采集完成，不等于已经获得完整 NAND/OOB、
一致性快照或经过实机验证的恢复方案；`fw_printenv` 等可选采集失败也必须单独补齐。

另外，待刷镜像内的升级脚本不能保护从旧系统发起的 sysupgrade，因为升级 hook 来自当前
运行系统。为消除误用，本阶段 profile 已完全关闭 sysupgrade/factory 产物，而不是仅依赖镜像
中的布局检查。

## 当前 RAM 测试阶段允许的恢复策略

NexaWrt 当前 RAM 测试设计要求持久 UBI 保持未附加且不改变闪存；在未来取得单独的
真机 RAM 启动批准后，首选恢复动作是：

1. 保留完整 UART 日志；
2. 若 initramfs 运行异常，从 RAM 中重启或断电重启；
3. 让 U-Boot 沿原有启动流程启动当前生产系统；
4. 启动后重新收集 `dmesg` 和 U-Boot 环境，并与基线比较。

如果一次 RAM 启动后无法恢复当前启动，**不要尝试猜测性写闪存修复**。保持设备状态，
保存串口日志，核对供电、加载地址、设备树、内核参数和原始 U-Boot 环境。没有经过验证
的逐字节恢复方案之前，不得把备份写回设备。

## 严禁作为“恢复手段”的操作

以下命令或等价操作都可能把可恢复故障升级为永久损坏：

```text
mtd write / mtd erase
flash_erase
nandwrite
ubiformat
ubimkvol / ubirmvol / ubirsvol
sysupgrade
saveenv（在未审查全部环境变化时）
```

尤其不得覆盖 `appsbl`/`appsbl_1`、`art`、`bdata`、`bootconfig`/
`bootconfig1`。不得直接刷官方 OpenWrt 镜像；官方镜像的布局和升级逻辑不能被视为与
本设备的 single-large-UBI v1 布局兼容。

## 任何持久化研究开始前的硬门槛

本文不授权任何闪存写入。若未来另行立项研究持久化安装，至少还需要独立完成：

- 对备份做多份存储和重复哈希校验；
- 证明 UART 和 U-Boot 恢复路径稳定可重复；
- 证明候选 initramfs 使用 `root=/dev/ram0`，不含 `ubi.mtd=` 或 `/dev/ubiblock`；
- 证明 RAM 启动期间持久 UBI 保持未附加、未挂载、未写入；
- 在单独批准的真机测试中证明 initramfs 能稳定启动且设备树、存储识别均正确；
- 明确每个 MTD/UBI 对象的用途、擦写粒度和坏块处理；
- 为本布局设计并同行审查逐步恢复方案；
- 单独批准具体的写入镜像、目标、偏移和校验方式。

在这些条件满足前，结论始终是：**只读、只在 RAM 中测试、不写闪存。**
