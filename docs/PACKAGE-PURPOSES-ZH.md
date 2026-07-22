# 软件包中文用途目录

NexaWrt 的浏览器组件选择器除了展示软件包名、版本和上游描述，还会加载
`components/package-purpose-zh.json`，为当前软件包分片中的每一个唯一
`source/package` 条目展示中文用途。目录由仓库内的确定性脚本生成，不在浏览器中调用在线翻译或 AI 服务。

## 质量层级

每条用途都带有一个 `quality` 字段。它表示中文说明的生成方式，不是软件包安全等级、稳定等级或推荐等级：

| 层级 | 含义 | 适用范围 |
| --- | --- | --- |
| `exact` | 针对已知软件包人工整理的精确用途说明 | 常用基础服务、LuCI 应用、网络工具等已有明确条目的软件包 |
| `family` | 根据可靠的软件包命名家族生成保守说明 | `luci-app-*`、`luci-i18n-*`、`kmod-*`、语言模块、共享库等可识别家族 |
| `category` | 无法可靠识别具体家族时，根据上游 feed/category 给出保守概述 | 其余软件包的兜底覆盖 |

因此，目录的 **100% 覆盖** 表示每个当前可见的唯一软件包键都有中文用途文本；其中包含
`family` 和 `category` 规则生成的说明，**不表示所有条目都经过逐包人工审阅**。如果规则无法可靠判断具体功能，说明必须保持概括，不得猜测软件包不存在的能力。网页会在每条说明前显示“人工精确”“家族规则生成”或
“分类概述，具体用途请核对上游”，并在目录状态中展示三个层级的条目数量，避免把完整性验证误解为逐包人工审核。

## 上游英文描述

中文用途是辅助发现和筛选的信息，不替代上游元数据。网页会把软件包分片中的原始英文
`description` 作为“上游说明 / Upstream”单独保留，用户可以同时核对中文用途与上游描述。
中文搜索会匹配用途文本，但构建请求仍只提交受目录约束的软件包标识，不提交描述文本。

## 完整性绑定

中文用途目录是软件包根目录的 sidecar 数据。`components/package-catalog.json` 中的
`purpose_catalog` 描述符绑定其固定路径、SHA-256、目录版本和条目数量。Pages 暂存阶段会：

1. 验证软件包根目录和全部分片；
2. 验证中文用途目录的文件类型、大小和 SHA-256；
3. 拒绝重复 JSON 键、未知字段、非法文本或未知质量层级；
4. 比较全部 `source/package` 键，拒绝缺失条目和额外条目；
5. 对大型目录执行最低质量门槛：至少 50 条 `exact`，且 `category` 占比不得超过 50%；
6. 只把通过验证的文件复制到 Pages 站点目录。

这个 sidecar 不改变软件包分片字节，也不改变社区候选包的来源投影摘要。

## 生成与验证

仅重新生成当前分片对应的中文用途文件：

```sh
python3 scripts/package_purpose_zh.py \
  --components-root components \
  --output components/package-purpose-zh.json \
  --update-index
```

该命令是确定性的：相同分片输入应产生逐字节相同的输出。`--update-index` 会在用途文件写入成功后，
自动更新 `components/package-catalog.json` 中 `purpose_catalog.sha256` 和 `package_count`；两个文件分别采用
安全的原子替换写入。若进程恰好在两次替换之间中断，后续验证会因为摘要或数量不匹配而拒绝发布，
不会把不一致目录部署到 Pages。正常的软件包目录全量刷新也会自动完成这一步：

```sh
python3 scripts/generate-package-catalog.py --output-root .
```

全量生成需要访问锁定的 OpenWrt 与社区元数据；不要在未审查上游变化时用它覆盖已提交目录。

运行中文用途单元测试：

```sh
python3 tests/test_package_purpose_zh.py
```

验证完整目录契约并安全暂存到 Pages 目录：

```sh
python3 scripts/validate-component-catalogs.py \
  --components-root components \
  --site-root site/components
```

运行 Pages 工作流策略测试：

```sh
bash tests/test_pages_policy.sh
```

## 维护规则

- 优先为高频、容易混淆或有风险边界的软件包补充 `exact` 说明；目录达到 1000 条后至少保留 50 条 `exact`，且 `category` 占比不得超过 50%。
- `family` 规则必须只描述由包名结构能够可靠确认的用途。
- `category` 说明必须明确而保守，不能把分类概述写成包级功能承诺。
- 中文文本不得含控制字符、双向文本控制符或 HTML；前端始终按纯文本渲染。
- 软件包新增、删除或来源变化时，必须重新生成并验证目录，保证键集合完全一致。
- 上游英文描述必须保留，不能用自动生成的中文用途覆盖或改写原始元数据。
