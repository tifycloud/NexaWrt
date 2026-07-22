# NexaWrt 自建 APK 软件库

NexaWrt 的 OpenWrt 基线是 **25.12**。这一代使用 APK 软件包管理器，因此本项目的软件库格式是：

- 软件包：`*.apk`
- 签名索引：`packages.adb`
- 仓库配置：`/etc/apk/repositories.d/nexawrt.list`
- 仓库公钥：`/etc/apk/keys/nexawrt-repository.pem`

它不是旧版 OpenWrt 的 OPKG/IPK 软件源，不能把 `Packages.gz`、`.ipk` 或 `/etc/opkg/customfeeds.conf` 直接混入 25.12 镜像。

## 当前 testing 仓库

- 频道：`testing`
- OpenWrt 系列：`25.12`
- 架构：`aarch64_cortex-a53`
- 索引：`https://tifycloud.github.io/NexaWrt/packages/25.12/testing/aarch64_cortex-a53/packages.adb`
- 版本锁：`manifests/package-repository.lock`
- 软件集合锁：`manifests/package-repository-packages.txt`
- 公钥：`manifests/package-repository-public.pem`

NexaWrt AX9000 配置会把仓库 URL 和公钥直接编译进 rootfs。启动后无需手工添加源，可以执行：

```sh
apk update
apk search nexawrt
apk add --simulate nexawrt-repository
apk add nexawrt-repository
nexawrt-repo-status
```

`--simulate` 只做依赖解析，不安装软件，适合先验证仓库可用性。

> 当前 AX9000 产物仍是 initramfs RAM-test 镜像。运行时安装的软件和配置位于 RAM，重启后不会保留；这不影响验证仓库、签名和依赖解析，但不能等同于持久化生产固件。

## 自动云编译与发布

`.github/workflows/package-repository.yml` 负责：

1. 从固定 OpenWrt commit 和固定 feeds 构建审核通过的软件包；
2. 仅从 `manifests/package-repository-packages.txt` 收集精确包名；
3. 仅在 `apk mkndx` 读取 public-only 构建输入 APK 时显式使用 `--allow-untrusted`，同时使用独立 P-256 仓库私钥签署最终 `packages.adb`；
4. 使用同一个 OpenWrt host `apk`、只含锁定公钥的临时 keys 目录执行真实 `apk verify packages.adb`；验签绝不使用 `--allow-untrusted`；
5. 验签成功后才生成 `SHA256SUMS`、`repository.json` 和版本化 tar.gz；
6. 创建不可覆盖的 GitHub prerelease；
7. 生成 GitHub build provenance attestation。

`repository.json` 的 `index` 对象严格绑定已验签 `packages.adb` 的文件名、SHA-256 和大小，并且只有真实验签成功后才写入 JSON 布尔值 `signature_verified: true`。用于验签的临时公钥目录位于仓库输出目录之外，完成后删除，不会进入归档。

Pages 工作流从精确 release tag 下载归档，同时核对 GitHub API asset digest、归档 SHA-256、目录边界、文件类型、`repository.json`、`index.signature_verified === true` 和所有 payload 摘要，再安全发布到 `site/packages/`。由于 GitHub asset digest、归档摘要和验签收据共同绑定了生产阶段已验签的精确索引字节，Pages 阶段不需要下载第二个 APK 工具。

发布版本不可覆盖。任何软件集合、源码或仓库元数据发生变化，都必须提高 `NEXAWRT_REPOSITORY_RELEASE` 并同步更新 release tag 和 asset 名称。

## 私钥边界

仓库只提交公钥。私钥：

- 不得提交到 Git；
- 不得复制进 OpenWrt `TOPDIR`、固件、artifact、日志或 Pages；
- 只允许由受保护的 GitHub Environment `package-repository` 中的 `NEXAWRT_REPOSITORY_SIGNING_PRIVATE_KEY` 提供给受信任的 `main` 分支发布 job；
- 在 step 内以 `0600` 临时文件生成，验证公钥指纹后只用于 `apk mkndx --sign`；随后使用锁定公钥验签最终索引并删除私钥；
- 必须另做离线加密备份。GitHub Actions secret 无法反向导出，丢失私钥后只能轮换公钥并发布新固件。

固件 APK 构建信任身份与在线软件库签名身份是两套独立密钥，不应复用。

## 如何增加软件

不能把网上找到的任意 IPK 直接搬进仓库。新增软件必须：

1. 固定可信源码仓库和 commit；
2. 审查 Makefile、下载脚本、补丁、默认配置和许可证；
3. 确认支持 OpenWrt 25.12 与 `aarch64_cortex-a53`；
4. 在构建树中生成 APK；
5. 把精确包名加入 `manifests/package-repository-packages.txt`；
6. 更新软件集合 SHA-256 和仓库发行版本；
7. 通过静态测试、构建、签名、Pages 暂存和虚拟/真机安装测试。

内核模块必须按精确 OpenWrt commit、kernel version 和 vermagic 分仓，不能把 official 与 NSS 的 kmod 混放。普通 LuCI 应用也不能因“网上存在”就自动获得信任；社区目录只负责发现候选，正式 APK 仓库只收录完成审查和可复现构建的软件。

## stable 频道条件

当前仓库是 `testing`。升级为 `stable` 前至少需要：

- GitHub Actions 完整构建和签名链路连续通过；
- Pages 上的 `packages.adb` 与 APK 可在线下载；
- APK 签名验证、`apk update`、模拟安装、实际安装和卸载通过；
- 依赖冲突、空间占用和失败回滚策略验证；
- AX9000 真机网络功能及重启行为验证；
- 独立安全审查批准密钥和发布权限边界。
