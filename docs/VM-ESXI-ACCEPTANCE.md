# NexaWrt x86_64：ESXi RC 验收与稳定版晋级门

本文定义 `vm-x86_64/v2` 的正式发布门：**已经发布的 RC 必须由用户在真实 VMware ESXi 上完成验收，并把机器可读证据提交到 `main`，之后才能把该 RC 的原始字节晋级为稳定版。**

## 安全边界

- ESXi 验收只能由实际操作 ESXi 的用户完成。自动化、维护者或 AI 不得把未执行的项目写成 `passed: true`，也不得生成虚假证据。
- 晋级工作流不调用 ImageBuilder、不编译、不转换镜像，也不修改资产名称或内容。
- 工作流只接受不可变、已发布且标记为 prerelease 的 RC。
- 稳定 tag 指向 RC 的同一 commit；稳定 Release 中的 21 个资产逐个来自指定 RC。
- 下载后先按 RC 自带的 `SHA256SUMS` 和五个相邻 `.sha256` 验证，再与已提交证据中的全部 21 个 SHA-256/大小绑定。
- 上传稳定草稿后，工作流会重新下载全部资产并逐字节比较；通过后才发布为非 prerelease。
- 该门只证明证据中记录的 **一个 VMDK、一个固件模式、一个 ESXi 主机环境**。它不代表所有 ESXi 版本/硬件均已验证，也不代表 AX9000 真机验证。

## 先决条件

1. RC tag 形如 `vm-x86_64-vX.Y.Z-rc.N`，例如 `vm-x86_64-v0.1.0-rc.4`。
2. RC Release 必须已发布、`prerelease=true`、`draft=false`、不可变，并符合 `vm-x86_64/v2` 的精确 21 资产合同。
3. 从该 RC 下载 BIOS 或 EFI VMDK；不要转换、解压后重新打包或改名。
4. 在 ESXi 中把 streamOptimized VMDK 导入/克隆为 datastore 上可写磁盘。虚拟机必须配置两张网卡：LAN 和 WAN 使用不同 Port Group。
5. 验收人必须能登录 ESXi、NexaWrt 控制台/LuCI，并能在 LAN 客户端执行 DHCP、NAT 和 DNS 测试。

## 必须人工执行的验收

以下各项都必须在证据中的对应对象记录为 `passed: true`；任何一项未执行或失败，都不能晋级。

### 1. VMDK 导入与启动

- 记录实际导入的 RC VMDK 完整资产名。
- 确认已创建 datastore-backed 可写磁盘，而不是直接把下载文件当长期可写基础盘。
- 确认虚拟机成功开机并进入 NexaWrt。
- `esxi.firmware` 必须与资产匹配：
  - `bios` → `...-generic-ext4-combined.vmdk`
  - `uefi` → `...-generic-ext4-combined-efi.vmdk`

### 2. 两网卡

- 必须正好记录 2 张网卡。
- LAN/WAN 接口名不能相同，LAN/WAN Port Group 不能相同。
- 建议 LAN 接隔离 Port Group，避免与现网其他 DHCP 服务冲突。

### 3. 管理面与防火墙

- 从 LAN 访问证据中记录的 `https.url`，记录 HTTP 状态和证书 SHA-256 指纹。
- 从 LAN 访问对应 `http.url`，确认返回 301/302/303/307/308，且 `Location` 为同一 LAN 地址的 HTTPS URL。
- 确认防火墙已启用且运行。
- 从 WAN 一侧确认 HTTP、HTTPS、SSH 等管理面不可访问，记录 `wan_management_blocked: true`。

### 4. WAN DHCP

- WAN 接口必须通过 DHCP 获得 IPv4 地址和默认网关。
- 证据中的 `wan_dhcp.interface` 必须与 `two_nics.wan_interface` 相同。

### 5. LAN DHCP、NAT、DNS

使用连接到 LAN Port Group 的独立客户端：

- 从 NexaWrt 获取 DHCP 租约，记录客户端 MAC 和 IPv4 地址。
- 使用该客户端访问 WAN 目标，确认 NAT 正常。
- 使用该客户端解析一个真实域名，记录查询名和至少一个解析出的 IPv4 地址。
- NAT/DNS 记录的客户端地址必须与 LAN DHCP 获得的地址一致。

### 6. 重启持久化

在修改一个可识别但安全的配置值（例如主机名）后，于重启前后分别记录：

```sh
cat /etc/nexawrt-install-id
(cd /etc/config && sha256sum * | LC_ALL=C sort | sha256sum)
uci -q get system.@system[0].hostname
uci -q get network.lan.ipaddr
```

证据必须满足：

- `/etc/nexawrt-install-id` 为 32 位小写十六进制值，重启前后完全相同。
- `/etc/config` 的确定性文件摘要重启前后完全相同。
- 主机名和 LAN IPv4 地址重启前后完全相同。
- 至少完成一次真实重启，不可只重启服务。

> `configuration_sha256_*` 填写上面第二条命令输出的第一个 64 位字段，不含文件名和空格。

## 证据文件

证据必须：

- 使用 UTF-8 JSON；
- 位于 `evidence/vm-esxi/*.json`；
- 被 Git 跟踪并已提交到当前 `main` 的 HEAD；
- 不得是符号链接，不得包含重复 JSON key；
- 严格符合 [`schemas/vm-esxi-evidence.schema.json`](../schemas/vm-esxi-evidence.schema.json)；
- 所有未知字段都会被拒绝；
- `tested_at` 使用 UTC 秒级时间，例如 `2026-07-20T12:30:00Z`，且不得早于 RC 发布时间；
- `rc_tag`、`release_version`、`rc_commit`、`release_contract` 与指定 RC 完全一致；
- `assets` 按下述合同顺序列出全部 21 个资产，不多不少，每项记录实际 SHA-256 和字节数。

### 21 资产顺序

其中 `${VERSION}` 是带 RC 后缀的版本，例如 `v0.1.0-rc.4`。

1. `NexaWrt-x86_64-${VERSION}-generic-ext4-combined.img.gz`
2. 上一项的 `.sha256`
3. `NexaWrt-x86_64-${VERSION}-generic-image.iso`
4. 上一项的 `.sha256`
5. `NexaWrt-x86_64-${VERSION}-generic-image-efi.iso`
6. 上一项的 `.sha256`
7. `NexaWrt-x86_64-${VERSION}-generic-ext4-combined.vmdk`
8. 上一项的 `.sha256`
9. `NexaWrt-x86_64-${VERSION}-generic-ext4-combined-efi.vmdk`
10. 上一项的 `.sha256`
11. `NexaWrt-x86_64-${VERSION}-generic.manifest`
12. `artifact-labels.env`
13. `README-VM.txt`
14. `smoke-report.txt`
15. `SHA256SUMS`
16. `raw-bios.provenance.bundle.json`
17. `iso-bios.provenance.bundle.json`
18. `iso-efi.provenance.bundle.json`
19. `vmdk-bios.provenance.bundle.json`
20. `vmdk-efi.provenance.bundle.json`
21. `checksums.provenance.bundle.json`

建议以 `schemas/vm-esxi-evidence.schema.json` 的 `required` 和 `properties` 为模板填写，不要添加自由字段。资产 SHA-256 和大小必须从下载的 RC 原始文件计算；不得复制其他版本的数据。

## 提交前本地验证

把指定 RC 的全部 21 个资产原样放在一个只包含这些文件的目录，然后执行：

```sh
python3 scripts/verify-vm-esxi-evidence.py \
  --schema schemas/vm-esxi-evidence.schema.json \
  --evidence evidence/vm-esxi/vX.Y.Z-rc.N.json \
  --repo-root "$PWD" \
  --release-dir /absolute/path/to/exact-rc-assets \
  --rc-tag vm-x86_64-vX.Y.Z-rc.N \
  --rc-commit 0123456789abcdef0123456789abcdef01234567 \
  --rc-published-at 2026-07-20T10:00:00Z
```

验证器会同时检查：路径安全、Git 已提交状态、严格 schema、未知字段、RC 身份、发布时间、21 资产精确集合、全部证据 SHA-256/大小、RC `SHA256SUMS`、五个相邻 `.sha256`，以及 `artifact-labels.env` 中的 tag/version/contract/commit。

## 晋级操作

1. 把真实证据 JSON 提交并合并到 `main`。
2. 打开 GitHub Actions → **Promote ESXi-accepted VM RC** → **Run workflow**。
3. Branch 必须选择 `main`。
4. 输入：
   - `rc_tag`: 精确 RC tag；
   - `evidence_path`: 仓库相对路径，例如 `evidence/vm-esxi/v0.1.0-rc.4.json`。
5. 工作流成功后得到稳定 tag `vm-x86_64-vX.Y.Z` 和非 prerelease Release。

稳定 Release 的资产名仍保留 `-rc.N`，这是证明“未重编译、字节未变化”的设计，不是命名错误。

## 失败、恢复与幂等重试

工作流允许在上传或字节比对中断后直接重试，但只会恢复由同一可信输入创建的对象：

- stable tag 不存在、stable Release 不存在：创建 tag 和草稿。
- stable tag 已存在但 Release 尚未创建：只有 tag 的对象类型为 commit 且精确指向当前 RC commit 时，才继续创建草稿。
- stable tag 和草稿都已存在：只有以下字段全部严格匹配时才恢复：
  - tag 精确指向当前 RC commit；
  - Release `tag_name`、`target_commitish`、名称完全匹配；
  - `draft=true`、`prerelease=false`；
  - Release body 与本次 RC tag、RC commit、证据路径、证据所在 `main` commit、测试人和测试范围生成的预期说明逐字一致。
- Release 存在但 tag 不存在，或任何身份字段不一致：立即拒绝，不删除资产、不覆盖 tag、不修改 Release。
- 已发布的稳定 Release 不属于可恢复对象；再次运行会拒绝，而不会尝试修改不可变正式版。

身份验证通过后，工作流会在上传前删除该可信草稿内的**全部已有资产**，确认草稿资产为空，再从已经校验的 RC 下载目录重新上传完整 21 资产。这样可以安全处理部分上传、错误字节或上次比对失败留下的草稿。上传后仍会重新下载、逐文件 `cmp`、比较完整 SHA-256 清单，并在发布前再次核对 Release 身份和资产 ID/名称没有变化。

推荐对失败的同一次工作流运行使用 GitHub 的 **Re-run failed jobs**，这样 `GITHUB_SHA` 和生成的 source notes 保持不变。若 `main` 已前进，新的手动运行生成的发布说明与旧草稿不一致时会按设计拒绝；仓库管理员必须先调查旧草稿，确认未发布后人工删除旧草稿和对应 stable tag，才能重新开始。工作流不会自动删除身份不匹配的对象。

- 在创建 stable 对象前失败：修正证据或 RC 问题后重新运行。
- 已发布稳定 Release 启用不可变后不得修改；如发现问题，发布新的 RC/版本，不得替换资产。
