# NexaWrt NSS flavor

## 状态与来源

NSS 是 NexaWrt 的**实验性、可选 flavor**，不是默认构建，也不是 official flavor 的替代品。
默认本地构建使用 `official`；Pull Request、main push 和 merge queue 只运行 official/NSS 双静态策略，
不会自动消耗完整固件构建资源。只有 GitHub Actions 手动触发时明确选择 `nss`，或在本地显式选择
NSS flavor，才应进入 NSS 完整构建路径。

| flavor | 上游来源 | 定位 |
| --- | --- | --- |
| `official` | 本仓库锁定的 OpenWrt `v25.12.5` / `f0a60eee...` | 默认、优先验证、最接近 OpenWrt 官方实现 |
| `nss` | `manifests/nss.lock` 锁定的 `qosmio/openwrt-ipq` `25.12-nss`，commit `d6848fa2ea00193b5b7d3973e3990da7f608027c` | 实验性加速对照组；不承诺稳定性、兼容性或性能收益 |

锁定的 NSS commit 日期是 **2026-06-06**，早于 official `v25.12.5` 锁定 commit 的
**2026-06-30**；两者对应的 Linux 版本分别是 **6.12.91** 与 **6.12.94**。分支名含有
`25.12-nss` 不代表它与 official `v25.12.5` 包含相同提交、安全修复或行为；本项目只记录
各自固定 revision，**不宣称两个 flavor 版本等价**。

NSS flavor 仍受项目现有的 AX9000 single-large-UBI v1、initramfs-only、禁止持久化刷写
等全部安全边界约束。**截至目前，真机 RAM 启动尚未获得批准；NSS 也没有例外。**

首个 NSS flavor 只验证有线 NSS/ECM 基础路径，并显式关闭 `ATH11K_NSS_SUPPORT`、NSS mesh
和 NSS SQM。无线仍走普通 ath11k 路径；Wi-Fi offload 必须在有线基线稳定后作为独立阶段评估。

本地 Linux 构建必须显式传入 flavor：

```sh
NEXAWRT_FLAVOR=nss ./scripts/build.sh
```

手动 GitHub Actions verified artifact 名包含 `nss`；Pull Request 不接受 flavor input，只执行
仓库静态策略。实验性 NSS 仍可通过独立的 `ram-test-nss-v*` prerelease tag 路径发布，但在真机门禁
完成前只属于 RAM-only 候选。

## NSS 与 ECM 可能带来的价值

Qualcomm Network SubSystem（NSS）把部分符合条件的数据面处理转移到专用网络处理核心；
ECM（Enterprise Connection Manager）负责观察连接、选择可加速的前端并管理连接的加速与
降速。对于能够进入 NSS 快速路径的流量，理论上可能降低主 CPU 的包处理和 softirq 压力，
并在高包速率或多流场景中改善可用吞吐、负载下延迟或功耗表现。

这些都是**待实测的假设，不是 NexaWrt 的实测结论**。协议、拓扑、MTU、桥接、VLAN、
防火墙、QoS、无线驱动和连接状态都会影响某条流是否能够加速。不能用“模块已加载”或
“ECM 有连接计数”代替端到端 A/B 测试，也不能据此宣称实际提速。

## 为什么它具有侵入性

NSS 不是一个可独立启停的普通用户态软件包。该 flavor 依赖下游内核、驱动、设备树、
网络栈、netfilter/ECM 接口和构建配置的组合，升级或回合 OpenWrt 官方实现时可能发生 API、
ABI 和行为差异。因此：

- OpenWrt 官方问题不能在 NSS flavor 上直接归因给官方上游；应先用 `official` 复现；
- 内核、firewall4、网络驱动或无线栈更新后必须重新验证，而不是假设旧结果继续成立；
- NSS 加速路径可能绕开或改变 Linux 主 CPU 上可观察到的包处理行为，抓包、计数器、QoS、
  策略路由和防火墙诊断需要同时观察慢路径与加速路径；
- 任何 NSS 构建必须保持明确的 flavor 身份和锁定来源，不能把两个 flavor 的包、overlay
  或构建缓存混用。

## 专有 firmware 与可审计性

NSS 运行依赖 Qualcomm 的专有二进制 firmware。该 firmware 不是与 Linux 内核同等可审计
的开源实现；故障分析、安全审计、修复节奏、许可证和再分发条件也可能受到上游二进制发布
方式约束。构建或分发前必须核对实际取得文件的许可证与来源。本项目采用 GPL-2.0-only
不能改变第三方 firmware 自身的许可条件。

Qualcomm firmware license notice 已随 NSS-only overlay 安装到镜像中的
`/usr/share/licenses/nss-firmware/LICENSE.md`；仓库级来源和再分发说明见
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。notice 只随 `nss` flavor 安装，
不得据此把 firmware 视为 GPL 组件或省略其二进制再分发条件。

如果缺少预期 firmware、firmware 版本不匹配、启动日志出现 NSS core/firmware 错误，必须
把 NSS flavor 判为失败；不要通过混入来历不明的二进制文件“修好”构建。

## 与 OpenWrt 其他转发加速机制的冲突

NSS/ECM 与 OpenWrt packet steering、software flow offloading、hardware flow offloading
属于竞争的数据面策略。为了让 A/B 结果可解释并避免重复或冲突的快速路径，NSS overlay
只对 NSS flavor 应用以下基线：

```uci
network.globals.packet_steering='0'
firewall.@defaults[0].flow_offloading='0'
firewall.@defaults[0].flow_offloading_hw='0'
```

对应文件是 `files-nss/etc/uci-defaults/20-nss-baseline`。这里使用命名 section 写法
`network.globals`；upstream UCI 也可以用 `network.@globals[0]` 访问同一个首个 `globals`
section。真正不能照搬的是参考 README 中把该选项写到 `network.@device[0]`，因为那是
`device` section，不是全局 network section。该默认脚本不得复制到 `files/`，因此不会
改变默认 `official` flavor。

上述设置只消除已知的竞争路径，不代表流量一定会被 NSS/ECM 加速。测试前后都应读取 UCI
和运行时 nftables 状态，确认没有意外启用 OpenWrt flow offload。

## bridge VLAN filtering 与 NSS Wi-Fi 限制

bridge VLAN filtering 和 NSS 加速 Wi-Fi 的组合存在集成限制，不能假设其行为与 OpenWrt
官方 Linux bridge/DSA/无线慢路径完全一致。尤其是 VLAN-aware bridge、按 SSID/端口划分
VLAN、tagged/untagged/PVID 混合以及无线客户端跨 VLAN 转发，可能无法进入预期快速路径，
也可能出现计数、策略或连通性差异。

因此：

1. 初始 NSS 吞吐 A/B 使用简单、无 VLAN filtering 的有线拓扑；
2. 需要 bridge VLAN filtering 或复杂 SSID/VLAN 隔离时，优先使用 `official`；
3. 必须验证 NSS Wi-Fi 时，把每个 VLAN、每个方向、tagged/untagged、客户端隔离和重连都
   作为独立兼容性测试，不能只做单次 `ping`；
4. 发现桥接/VLAN/无线行为异常时，停止 NSS 测试并回到 `official` 复现；不要为了追求加速
   放宽隔离或防火墙规则。

## 只读诊断

`scripts/nss-diagnostics.sh` 从标准输出收集以下状态：

- NSS firmware 文件与相关内核日志；
- NSS、ECM、PPE、EDMA 和相关 Wi-Fi 模块及只读参数；
- 已存在 debugfs 中的 NSS/ECM 状态（脚本不会主动挂载 debugfs）；
- CPU、softirq、IRQ 与 affinity；
- packet steering、软件/硬件 flow offload 和运行时 nftables flowtable；
- bridge、VLAN filtering、端口 VLAN 和无线接口状态。

该脚本读取的是**被测路由器**的 `/proc`、`/sys`、UCI、nftables、bridge 与无线状态，
不能直接在开发机仓库目录运行。只有在真机 RAM 启动获得单独批准、并确认 SSH 连接到该台
AX9000 后，才可从开发机通过 SSH stdin 把脚本送入路由器的内存中执行，并把 stdout 保存
在开发机：

```sh
ssh root@ROUTER_IP 'sh -s' < scripts/nss-diagnostics.sh \
  > "nss-diagnostics-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

当前仍**未批准任何真机 RAM 启动或上述诊断命令**；这只是获批后的只读采集方式，不是执行
授权。不要把脚本复制到持久存储，也不要在构建机本地运行后把构建机状态误当成 AX9000
结果。脚本自身不创建文件、不写闪存、不调用 `uci set`/`uci commit`、不挂载文件系统，也不
加载或卸载模块。输出可能包含接口名、MAC、IP、内核日志和设备信息，公开前仍需人工脱敏。

## A/B 验证与结论边界

`official` 是 A 组和默认基线，`nss` 是 B 组实验变量。完整方法见
[测试文档](TESTING.md#8-officialnss-ab-测试方法)。除 flavor 及其必要 overlay/包外，应保持
镜像来源记录、设备、供电、拓扑、客户端、线缆、MTU、测试工具、并发数、方向和测试时长
一致，并保存原始日志。

在真机 RAM 启动获批且 A/B 数据经过复核前，只能表述为“提供实验性 NSS flavor”或
“观察到某次测试结果”，不能写成“已提速”“性能提升百分比”或“比 official 更稳定”。
