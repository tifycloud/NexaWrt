#!/usr/bin/env python3
"""Generate a deterministic Chinese-purpose catalog for OpenWrt packages.

The generator reads every ``components/packages/*.json`` shard, de-duplicates
records by ``source/package``, and emits a compact catalog whose descriptions
are deliberately conservative: well-known packages use reviewed exact text,
recognized package families use naming rules, and all remaining packages use
feed/category-level fallback text without inventing capabilities.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Mapping

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_VERSION = 1
QUALITIES = ("exact", "family", "category")
TOP_LEVEL_KEYS = (
    "schema_version",
    "catalog_version",
    "package_count",
    "quality_counts",
    "purposes",
)
PURPOSE_KEYS = ("purpose", "quality")
PACKAGE_PART_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
CHINESE_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
MAX_PURPOSE_LENGTH = 360
LARGE_CATALOG_THRESHOLD = 1000
MIN_EXACT_PURPOSES = 50
MAX_CATEGORY_SHARE = 0.50
ALLOWED_SOURCES = {"official", "kiddin9"}
INDEX_KEYS = {"schema_version", "catalog_version", "openwrt_version", "purpose_catalog", "shards"}
PURPOSE_DESCRIPTOR_KEYS = {"locale", "path", "sha256", "package_count"}
PURPOSE_RELATIVE_PATH = "components/package-purpose-zh.json"


class PurposeCatalogError(ValueError):
    """Raised when package input or a generated purpose catalog is invalid."""


# Reviewed descriptions for common packages. These describe only established,
# package-specific behavior and intentionally avoid deployment promises.
EXACT_PURPOSES: dict[str, str] = {
    # OpenWrt base system and network services.
    "base-files": "提供 OpenWrt 基础文件系统、默认配置和核心系统脚本。",
    "busybox": "提供适合嵌入式系统的常用 Linux 命令行工具集合。",
    "uci": "提供 OpenWrt 统一配置接口，用于读写系统的 UCI 配置。",
    "ubus": "提供 OpenWrt 进程间通信总线及其命令行客户端。",
    "rpcd": "提供 OpenWrt 的 RPC 后端服务，供 LuCI 等管理界面调用系统功能。",
    "procd": "提供 OpenWrt 的进程管理、服务守护和系统初始化功能。",
    "firewall4": "提供基于 nftables 的 OpenWrt 防火墙规则生成与管理功能。",
    "dnsmasq": "为局域网提供轻量级 DNS 转发和 DHCP 服务。",
    "dnsmasq-full": "提供功能较完整的 DNS 转发与 DHCP 服务变体，包括更多可选特性。",
    "odhcp6c": "提供 DHCPv6 客户端，用于从上游网络获取 IPv6 配置。",
    "odhcpd-ipv6only": "为局域网提供 IPv6 路由通告和 DHCPv6 服务。",
    "dropbear": "提供适合嵌入式设备的轻量级 SSH 服务和客户端工具。",
    "openssh-server": "提供 OpenSSH 远程登录服务器。",
    "ca-bundle": "提供常用根证书集合，用于校验 TLS 服务器证书。",
    "curl": "提供支持多种网络协议的命令行数据传输工具。",
    "wget-ssl": "提供支持 HTTPS 的命令行文件下载工具。",
    "ip-full": "提供完整版 ip 命令，用于管理地址、路由、链路和网络策略。",
    "tc-full": "提供完整版流量控制工具，用于配置队列、整形和分类规则。",
    "ethtool": "用于查看和调整以太网接口、链路及网卡驱动参数。",
    "iperf3": "用于测量两台设备之间的 TCP、UDP 或 SCTP 网络吞吐性能。",
    "librespeed-cli": "提供 LibreSpeed 网络测速服务的命令行客户端。",
    "librespeed-go": "提供使用 Go 实现的 LibreSpeed 自托管网络测速服务端。",
    "irqbalance": "在多核处理器之间分配硬件中断，以改善中断负载均衡。",
    "sqm-scripts": "提供智能队列管理脚本，用于缓解网络拥塞时的延迟和缓冲膨胀。",
    "mwan3": "提供多 WAN 接口的策略路由、故障转移和负载分担框架。",
    # LuCI core and common applications.
    "luci": "安装 OpenWrt 标准 LuCI 网页管理界面及常用管理组件。",
    "luci-base": "提供 LuCI 网页管理界面的核心运行库、调度和基础资源。",
    "luci-mod-admin-full": "提供 LuCI 完整系统管理页面模块。",
    "luci-app-firewall": "提供防火墙、端口转发和通信规则的 LuCI 网页配置界面。",
    "luci-app-package-manager": "提供软件包查询、安装、升级和卸载的 LuCI 管理界面。",
    "luci-app-attendedsysupgrade": "提供 LuCI 在线请求兼容升级镜像并执行系统升级的界面。",
    "luci-app-ttyd": "在 LuCI 中提供基于浏览器的终端入口。",
    "luci-app-sqm": "提供 SQM 智能队列管理的 LuCI 配置界面。",
    "luci-app-mwan3": "提供 mwan3 多 WAN 策略路由的 LuCI 配置界面。",
    "luci-theme-bootstrap": "提供 LuCI 默认 Bootstrap 网页主题。",
    "luci-proto-ipv6": "为 LuCI 网络配置提供常用 IPv6 接口协议支持。",
    # VPN and encrypted overlay networking.
    "wireguard-tools": "提供 WireGuard VPN 的密钥生成和隧道配置命令行工具。",
    "luci-proto-wireguard": "为 LuCI 网络配置提供 WireGuard 接口协议支持。",
    "openvpn-openssl": "提供使用 OpenSSL 加密后端的 OpenVPN 客户端和服务器程序。",
    "luci-app-openvpn": "提供 OpenVPN 实例的 LuCI 配置与启停管理界面。",
    "strongswan": "提供 strongSwan IPsec VPN 的共享组件和运行脚本。",
    "libreswan": "提供 Libreswan IPsec VPN 的密钥交换和隧道管理程序。",
    "libreswan-iptables": "为 Libreswan IPsec VPN 提供基于 iptables 的防火墙集成脚本。",
    "libreswan-nftables": "为 Libreswan IPsec VPN 提供基于 nftables 的防火墙集成脚本。",
    "tailscale": "提供基于 WireGuard 的 Tailscale 加密组网客户端。",
    "zerotier": "提供 ZeroTier 虚拟网络客户端，用于跨网络建立加密覆盖网络。",
    "luci-app-openclash": "提供 OpenClash 代理服务的 LuCI 配置与状态管理界面。",
    "openclash": "提供基于 Clash 内核的 OpenWrt 代理规则管理服务。",
    "luci-app-passwall": "提供 PassWall 代理客户端的 LuCI 配置界面。",
    "luci-app-passwall2": "提供 PassWall 2 代理客户端的 LuCI 配置界面。",
    "luci-app-ssr-plus": "提供 SSR Plus 代理客户端的 LuCI 配置界面。",
    "mihomo": "提供兼容 Clash 配置的 Mihomo 网络代理核心。",
    # DNS and name-resolution tools.
    "adguardhome": "提供全网 DNS 广告与跟踪域名拦截服务。",
    "smartdns": "提供本地 DNS 服务，可并行查询多个上游并按策略选择结果。",
    "https-dns-proxy": "将本地普通 DNS 查询转发为 DNS-over-HTTPS 请求。",
    "bind-dig": "提供 dig 等 DNS 查询与诊断命令行工具。",
    # Storage and file sharing.
    "block-mount": "提供块设备识别、挂载及 OpenWrt fstab 配置支持。",
    "e2fsprogs": "提供 ext2、ext3 和 ext4 文件系统的创建、检查与维护工具。",
    "f2fs-tools": "提供 F2FS 文件系统的创建、检查和维护工具。",
    "ntfs-3g": "通过 FUSE 提供 NTFS 文件系统的读写支持。",
    "kmod-usb-storage": "提供 USB 大容量存储设备所需的内核驱动支持。",
    "kmod-fs-ext4": "提供 ext4 文件系统的内核支持。",
    "kmod-fs-f2fs": "提供 F2FS 文件系统的内核支持。",
    "usbutils": "提供 lsusb 等 USB 设备查看和诊断工具。",
    "samba4-server": "提供 Samba 4 SMB/CIFS 文件共享服务器。",
    "luci-app-samba4": "提供 Samba 4 网络文件共享的 LuCI 配置界面。",
    # Containers.
    "docker": "提供 Docker 容器平台的命令行客户端。",
    "dockerd": "提供 Docker 容器引擎守护进程。",
    "containerd": "提供负责容器镜像、生命周期和运行任务管理的容器运行时。",
    "runc": "提供依据 OCI 规范创建和运行容器的低层运行工具。",
    "podman": "提供无需常驻守护进程的 OCI 容器与 Pod 管理工具。",
    "docker-compose": "提供通过 Compose 配置定义和管理多容器应用的工具。",
    "luci-app-dockerman": "提供 Docker 容器、镜像和相关资源的 LuCI 管理界面。",
    # Monitoring and diagnostics.
    "collectd": "周期采集系统和服务指标，并交由插件存储或转发用于监控。",
    "luci-app-statistics": "提供 collectd 监控指标的 LuCI 配置和图表展示界面。",
    "prometheus-node-exporter-lua": "提供轻量级 Prometheus 节点指标采集端点。",
    "vnstat2": "使用 vnStat 统计并保存网络接口流量数据。",
    "luci-app-vnstat2": "提供 vnStat 2 网络流量统计的 LuCI 展示与配置界面。",
    "htop": "提供交互式终端进程和系统资源监视器。",
    # Common runtimes and editors.
    "python3": "提供 Python 3 解释器和标准运行环境。",
    "perl": "提供 Perl 语言解释器和基础运行环境。",
    "ruby": "提供 Ruby 语言解释器和基础运行环境。",
    "php8": "提供 PHP 8 脚本语言的基础运行环境。",
    "nano": "提供轻量、易用的终端文本编辑器。",
    "vim-full": "提供包含常用完整特性的 Vim 终端文本编辑器。",
}

FEED_PURPOSES: dict[str, str] = {
    "target": "OpenWrt 目标平台相关软件包；仅凭目录分类无法可靠判断更具体用途。",
    "base": "OpenWrt 基础系统软件包；仅凭目录分类无法可靠判断更具体用途。",
    "kmods": "OpenWrt 内核或硬件支持软件包；具体用途和兼容性需查看上游包说明。",
    "luci": "OpenWrt LuCI 网页界面相关软件包；仅凭目录分类无法可靠判断更具体用途。",
    "packages": "OpenWrt 通用扩展软件包；仅凭目录分类无法可靠判断更具体用途。",
    "routing": "OpenWrt 路由协议或网络控制相关软件包；具体作用需查看上游包说明。",
    "telephony": "OpenWrt 语音或通信服务相关软件包；具体作用需查看上游包说明。",
    "video": "OpenWrt 视频或多媒体相关软件包；具体作用需查看上游包说明。",
    "kiddin9": "第三方社区候选软件包；具体用途、来源可信度和设备兼容性需另行核验。",
}

CATEGORY_PURPOSES: dict[str, str] = {
    "official-target": "OpenWrt 目标平台相关软件包；仅凭目录分类无法可靠判断更具体用途。",
    "official-base": "OpenWrt 基础系统软件包；仅凭目录分类无法可靠判断更具体用途。",
    "official-kernel": "OpenWrt 内核或硬件支持软件包；具体用途和兼容性需查看上游包说明。",
    "official-luci": "OpenWrt LuCI 网页界面相关软件包；仅凭目录分类无法可靠判断更具体用途。",
    "official-packages": "OpenWrt 通用扩展软件包；仅凭目录分类无法可靠判断更具体用途。",
    "official-routing": "OpenWrt 路由协议或网络控制相关软件包；具体作用需查看上游包说明。",
    "official-telephony": "OpenWrt 语音或通信服务相关软件包；具体作用需查看上游包说明。",
    "official-video": "OpenWrt 视频或多媒体相关软件包；具体作用需查看上游包说明。",
    "community-kiddin9": "第三方社区候选软件包；具体用途、来源可信度和设备兼容性需另行核验。",
}

GENERIC_CATEGORY_PURPOSE = (
    "OpenWrt 软件包；现有目录信息不足以可靠判断具体用途，请在安装前查看上游说明。"
)


def _has_control_characters(value: str) -> bool:
    return any(unicodedata.category(character) in {"Cc", "Cf"} for character in value)


def _require_plain_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise PurposeCatalogError(f"{label} must be a non-empty trimmed string")
    if _has_control_characters(value):
        raise PurposeCatalogError(f"{label} contains control characters")
    return value


def _package_key(source: Any, package: Any, label: str) -> str:
    source_text = _require_plain_string(source, f"{label}.source")
    package_text = _require_plain_string(package, f"{label}.package")
    if source_text not in ALLOWED_SOURCES:
        raise PurposeCatalogError(f"{label}.source is unsupported")
    if not PACKAGE_PART_RE.fullmatch(package_text):
        raise PurposeCatalogError(f"{label}.package contains unsupported characters")
    return f"{source_text}/{package_text}"


def _family_purpose(package: str) -> str | None:
    if package.startswith("luci-i18n-"):
        rest = package.removeprefix("luci-i18n-")
        language = next(
            (locale for locale in ("pt-br", "zh-cn", "zh-tw") if rest.endswith(f"-{locale}")),
            rest.rpartition("-")[2],
        )
        component = rest[: -(len(language) + 1)] if language else ""
        separator = "-" if component and language else ""
        if separator and component and language:
            return f"为 LuCI 组件“{component}”提供“{language}”语言翻译资源。"
        return "为 LuCI 组件提供界面翻译资源；具体语言和对应组件由软件包名称标识。"

    if package.startswith("luci-app-"):
        component = package.removeprefix("luci-app-")
        return (
            f"为“{component}”相关服务提供 LuCI 网页管理入口；"
            "实际功能取决于对应后端软件包。"
        )

    if package.startswith("luci-proto-"):
        protocol = package.removeprefix("luci-proto-")
        return (
            f"为“{protocol}”网络协议或接口类型提供 LuCI 配置支持；"
            "实际连接能力由对应系统组件提供。"
        )

    if package.startswith("luci-theme-"):
        theme = package.removeprefix("luci-theme-")
        return f"提供名为“{theme}”的 LuCI 网页界面主题，不改变路由功能。"

    if package.startswith("kmod-"):
        subject = package.removeprefix("kmod-")
        return (
            f"OpenWrt 内核模块包，用于提供与“{subject}”相关的驱动或协议支持；"
            "具体功能和硬件兼容性以目标内核说明为准。"
        )

    if package.startswith("collectd-mod-"):
        plugin = package.removeprefix("collectd-mod-")
        return f"为 collectd 提供“{plugin}”指标采集、处理或输出插件。"

    if package == "python3-base":
        return "提供 Python 3 最小基础运行环境，供其他 Python 软件包依赖。"
    if package.startswith("python3-"):
        module = package.removeprefix("python3-")
        return f"为 Python 3 提供“{module}”模块或配套运行组件。"

    if package.startswith("perlbase-"):
        module = package.removeprefix("perlbase-")
        return f"提供 Perl 基础运行环境中的“{module}”模块。"
    if package.startswith("perl-"):
        module = package.removeprefix("perl-")
        return f"为 Perl 提供“{module}”模块或配套运行组件。"

    if package.startswith("ruby-"):
        module = package.removeprefix("ruby-")
        return f"为 Ruby 提供“{module}”库、扩展或配套运行组件。"

    if re.match(r"^php\d*(?:-mod-|-)", package):
        module = re.sub(r"^php\d*(?:-mod-|-)", "", package)
        return f"为 PHP 运行环境提供“{module}”扩展或配套组件。"

    # OpenWrt shared libraries conventionally use a compact lib* package name.
    if (
        package.startswith("lib")
        and len(package) > 3
        and not package.startswith(("libertas-", "librespeed-", "libreswan"))
    ):
        return (
            f"提供“{package}”共享库或运行时依赖，通常由其他软件调用，"
            "本身不提供独立管理功能。"
        )

    return None


def purpose_for_record(record: Mapping[str, Any]) -> tuple[str, str]:
    """Return ``(purpose, quality)`` for one normalized package record."""

    package = str(record["package"])
    exact = EXACT_PURPOSES.get(package)
    if exact is not None:
        return exact, "exact"

    family = _family_purpose(package)
    if family is not None:
        return family, "family"

    feed = record.get("feed")
    if isinstance(feed, str) and feed in FEED_PURPOSES:
        return FEED_PURPOSES[feed], "category"

    category = record.get("category")
    if isinstance(category, str) and category in CATEGORY_PURPOSES:
        return CATEGORY_PURPOSES[category], "category"

    return GENERIC_CATEGORY_PURPOSE, "category"


def load_package_shards(
    components_root: str | Path,
) -> tuple[dict[str, list[dict[str, Any]]], str]:
    """Load package records by shard and return them with one catalog version."""

    package_dir = Path(components_root) / "packages"
    shard_paths = sorted(package_dir.glob("*.json"))
    if not shard_paths:
        raise PurposeCatalogError(f"no package shards found below {package_dir}")

    catalog_versions: set[str] = set()
    records_by_shard: dict[str, list[dict[str, Any]]] = {}
    for shard_path in shard_paths:
        try:
            payload = json.loads(shard_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise PurposeCatalogError(f"cannot read package shard {shard_path}: {error}") from error

        if not isinstance(payload, dict):
            raise PurposeCatalogError(f"package shard {shard_path} must be an object")
        catalog_versions.add(
            _require_plain_string(
                payload.get("catalog_version"), f"{shard_path}.catalog_version"
            )
        )
        packages = payload.get("packages")
        if not isinstance(packages, list):
            raise PurposeCatalogError(f"{shard_path}.packages must be an array")
        records_by_shard[shard_path.name] = packages

    if len(catalog_versions) != 1:
        raise PurposeCatalogError(
            "all package shards must use one catalog_version; found "
            + ", ".join(sorted(catalog_versions))
        )
    return records_by_shard, next(iter(catalog_versions))


def _unique_records(
    records_by_shard: Mapping[str, Iterable[Mapping[str, Any]]],
) -> dict[str, dict[str, str]]:
    if not isinstance(records_by_shard, Mapping) or not records_by_shard:
        raise PurposeCatalogError("records_by_shard must be a non-empty mapping")

    candidates: dict[str, set[tuple[str, str]]] = {}
    for shard_name in sorted(records_by_shard):
        _require_plain_string(shard_name, "shard name")
        records = records_by_shard[shard_name]
        if isinstance(records, (str, bytes, Mapping)) or not isinstance(records, Iterable):
            raise PurposeCatalogError(f"{shard_name} records must be an iterable of objects")
        for index, record in enumerate(records):
            label = f"{shard_name}[{index}]"
            if not isinstance(record, Mapping):
                raise PurposeCatalogError(f"{label} must be an object")
            key = _package_key(record.get("source"), record.get("package"), label)
            feed = record.get("feed", "")
            category = record.get("category", "")
            if not isinstance(feed, str) or _has_control_characters(feed):
                raise PurposeCatalogError(f"{label}.feed must be a control-free string")
            if not isinstance(category, str) or _has_control_characters(category):
                raise PurposeCatalogError(f"{label}.category must be a control-free string")
            candidates.setdefault(key, set()).add((feed, category))

    records: dict[str, dict[str, str]] = {}
    for key in sorted(candidates):
        source, package = key.split("/", 1)
        # Duplicate source/package entries can occur in several target shards.
        # Lexicographic selection makes the result independent of input order.
        feed, category = min(candidates[key])
        records[key] = {
            "source": source,
            "package": package,
            "feed": feed,
            "category": category,
        }
    return records


def build_purpose_catalog(
    records_by_shard: Mapping[str, Iterable[Mapping[str, Any]]],
    catalog_version: str,
) -> dict[str, Any]:
    """Build a validated catalog from package records already loaded by a caller."""

    version = _require_plain_string(catalog_version, "catalog_version")
    records = _unique_records(records_by_shard)
    purposes: dict[str, dict[str, str]] = {}
    counts: Counter[str] = Counter()

    for key in sorted(records):
        purpose, quality = purpose_for_record(records[key])
        purposes[key] = {"purpose": purpose, "quality": quality}
        counts[quality] += 1

    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "catalog_version": version,
        "package_count": len(purposes),
        "quality_counts": {quality: counts[quality] for quality in QUALITIES},
        "purposes": purposes,
    }
    validate_purpose_catalog(payload, version, purposes.keys())
    return payload


def validate_purpose_catalog(
    payload: Any,
    expected_catalog_version: str,
    expected_keys: Iterable[str] | None = None,
) -> None:
    """Strictly validate the fixed Chinese-purpose catalog schema.

    ``expected_keys`` may be supplied by a caller that already knows the
    complete ``source/package`` set. Validation succeeds by returning ``None``
    and raises :class:`PurposeCatalogError` on any mismatch.
    """

    if not isinstance(payload, dict) or set(payload) != set(TOP_LEVEL_KEYS):
        raise PurposeCatalogError(
            "catalog top-level keys must be exactly: " + ", ".join(TOP_LEVEL_KEYS)
        )
    if payload["schema_version"] != SCHEMA_VERSION or isinstance(
        payload["schema_version"], bool
    ):
        raise PurposeCatalogError(f"schema_version must be integer {SCHEMA_VERSION}")

    expected_version = _require_plain_string(
        expected_catalog_version, "expected_catalog_version"
    )
    catalog_version = _require_plain_string(payload["catalog_version"], "catalog_version")
    if catalog_version != expected_version:
        raise PurposeCatalogError(
            f"catalog_version mismatch: expected {expected_version}, got {catalog_version}"
        )

    package_count = payload["package_count"]
    if isinstance(package_count, bool) or not isinstance(package_count, int) or package_count < 0:
        raise PurposeCatalogError("package_count must be a non-negative integer")

    quality_counts = payload["quality_counts"]
    if not isinstance(quality_counts, dict) or set(quality_counts) != set(QUALITIES):
        raise PurposeCatalogError(
            "quality_counts keys must be exactly: " + ", ".join(QUALITIES)
        )
    for quality in QUALITIES:
        count = quality_counts[quality]
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise PurposeCatalogError(f"quality_counts.{quality} must be a non-negative integer")

    purposes = payload["purposes"]
    if not isinstance(purposes, dict):
        raise PurposeCatalogError("purposes must be an object")
    if list(purposes) != sorted(purposes):
        raise PurposeCatalogError("purposes keys must be sorted")
    if package_count != len(purposes):
        raise PurposeCatalogError("package_count does not match purposes size")

    actual_counts: Counter[str] = Counter()
    for key, entry in purposes.items():
        key_text = _require_plain_string(key, "purpose key")
        if key_text.count("/") != 1:
            raise PurposeCatalogError(f"invalid source/package key: {key_text}")
        source, package = key_text.split("/", 1)
        if not PACKAGE_PART_RE.fullmatch(source) or not PACKAGE_PART_RE.fullmatch(package):
            raise PurposeCatalogError(f"invalid source/package key: {key_text}")
        if not isinstance(entry, dict) or set(entry) != set(PURPOSE_KEYS):
            raise PurposeCatalogError(
                f"{key_text} keys must be exactly: " + ", ".join(PURPOSE_KEYS)
            )
        purpose = _require_plain_string(entry["purpose"], f"{key_text}.purpose")
        if len(purpose) > MAX_PURPOSE_LENGTH:
            raise PurposeCatalogError(
                f"{key_text}.purpose exceeds {MAX_PURPOSE_LENGTH} characters"
            )
        if not CHINESE_RE.search(purpose):
            raise PurposeCatalogError(f"{key_text}.purpose must contain Chinese text")
        quality = entry["quality"]
        if quality not in QUALITIES:
            raise PurposeCatalogError(
                f"{key_text}.quality must be one of: " + ", ".join(QUALITIES)
            )
        actual_counts[quality] += 1

    normalized_counts = {quality: actual_counts[quality] for quality in QUALITIES}
    if quality_counts != normalized_counts:
        raise PurposeCatalogError("quality_counts does not match purposes entries")
    if sum(quality_counts.values()) != package_count:
        raise PurposeCatalogError("quality_counts total does not match package_count")
    if package_count >= LARGE_CATALOG_THRESHOLD:
        if quality_counts["exact"] < MIN_EXACT_PURPOSES:
            raise PurposeCatalogError(
                f"large catalogs require at least {MIN_EXACT_PURPOSES} exact purposes"
            )
        if quality_counts["category"] / package_count > MAX_CATEGORY_SHARE:
            raise PurposeCatalogError(
                f"category purposes exceed the {MAX_CATEGORY_SHARE:.0%} quality ceiling"
            )

    if expected_keys is not None:
        normalized_expected: set[str] = set()
        for key in expected_keys:
            if not isinstance(key, str):
                raise PurposeCatalogError("expected_keys must contain only strings")
            normalized_expected.add(key)
        actual_keys = set(purposes)
        if actual_keys != normalized_expected:
            missing = sorted(normalized_expected - actual_keys)
            extra = sorted(actual_keys - normalized_expected)
            raise PurposeCatalogError(
                f"purposes keys mismatch: missing={missing[:5]}, extra={extra[:5]}"
            )


def canonical_json(payload: Mapping[str, Any]) -> bytes:
    """Return deterministic UTF-8 JSON bytes in the fixed schema order."""

    if not isinstance(payload, Mapping):
        raise PurposeCatalogError("catalog must be an object")
    catalog_version = payload.get("catalog_version")
    validate_purpose_catalog(payload, catalog_version)
    purposes = payload["purposes"]
    normalized = {
        "schema_version": payload["schema_version"],
        "catalog_version": payload["catalog_version"],
        "package_count": payload["package_count"],
        "quality_counts": {
            quality: payload["quality_counts"][quality] for quality in QUALITIES
        },
        "purposes": {
            key: {
                "purpose": purposes[key]["purpose"],
                "quality": purposes[key]["quality"],
            }
            for key in sorted(purposes)
        },
    }
    return (
        json.dumps(
            normalized,
            ensure_ascii=False,
            indent=2,
            separators=(",", ": "),
        )
        + "\n"
    ).encode("utf-8")


def _validate_atomic_write_target(output_path: Path) -> None:
    """Reject unsafe output parents, symbolic links, and multiply linked files."""

    output_path.parent.mkdir(parents=True, exist_ok=True)
    parent_stat = output_path.parent.lstat()
    if not stat.S_ISDIR(parent_stat.st_mode) or stat.S_ISLNK(parent_stat.st_mode):
        raise PurposeCatalogError(f"output parent is not a regular directory: {output_path.parent}")
    try:
        current = output_path.lstat()
    except FileNotFoundError:
        current = None
    if current is not None and (not stat.S_ISREG(current.st_mode) or current.st_nlink != 1):
        raise PurposeCatalogError(f"refusing unsafe output target: {output_path}")


def _atomic_write_bytes(output_path: Path, data: bytes) -> None:
    """Replace one regular file without following links or hard links."""

    # Re-check immediately before use even when the caller already performed a
    # multi-file preflight, reducing the check/use race window.
    _validate_atomic_write_target(output_path)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=output_path.parent,
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        temporary_path.chmod(0o644)
        os.replace(temporary_path, output_path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def write_purpose_catalog(payload: Mapping[str, Any], output: str | Path) -> None:
    """Write canonical UTF-8 JSON atomically after schema validation."""

    _atomic_write_bytes(Path(output), canonical_json(payload))


def package_index_descriptor_bytes(
    index_path: str | Path, payload: Mapping[str, Any], purpose_bytes: bytes
) -> bytes:
    """Validate the root index and return its updated canonical bytes."""

    path = Path(index_path)
    try:
        index = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PurposeCatalogError(f"cannot read package index {path}: {error}") from error
    if not isinstance(index, dict) or set(index) != INDEX_KEYS or index.get("schema_version") != 3:
        raise PurposeCatalogError("package index must use the exact schema_version 3 contract")
    if index.get("catalog_version") != payload.get("catalog_version"):
        raise PurposeCatalogError("package index and purpose catalog versions differ")
    descriptor = index.get("purpose_catalog")
    if not isinstance(descriptor, dict) or set(descriptor) != PURPOSE_DESCRIPTOR_KEYS:
        raise PurposeCatalogError("package index purpose descriptor has unexpected keys")
    if descriptor.get("locale") != "zh-CN" or descriptor.get("path") != PURPOSE_RELATIVE_PATH:
        raise PurposeCatalogError("package index purpose descriptor identity is invalid")
    index["purpose_catalog"] = {
        "locale": "zh-CN",
        "path": PURPOSE_RELATIVE_PATH,
        "sha256": hashlib.sha256(purpose_bytes).hexdigest(),
        "package_count": payload["package_count"],
    }
    return (
        json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def update_package_index_descriptor(
    index_path: str | Path, payload: Mapping[str, Any], purpose_bytes: bytes
) -> None:
    """Validate and atomically update the generated-purpose descriptor."""

    path = Path(index_path)
    _atomic_write_bytes(path, package_index_descriptor_bytes(path, payload, purpose_bytes))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--components-root",
        type=Path,
        default=ROOT / "components",
        help="components directory containing packages/*.json",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "components" / "package-purpose-zh.json",
        help="output JSON path",
    )
    parser.add_argument(
        "--update-index",
        action="store_true",
        help="also update components/package-catalog.json with the generated SHA and count",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        records_by_shard, catalog_version = load_package_shards(args.components_root)
        payload = build_purpose_catalog(records_by_shard, catalog_version)
        purpose_bytes = canonical_json(payload)
        index_path: Path | None = None
        index_bytes: bytes | None = None
        if args.update_index:
            expected_output = args.components_root.resolve() / "package-purpose-zh.json"
            if args.output.resolve() != expected_output:
                raise PurposeCatalogError(
                    "--update-index requires --output to be components/package-purpose-zh.json"
                )
            index_path = args.components_root / "package-catalog.json"
            index_bytes = package_index_descriptor_bytes(index_path, payload, purpose_bytes)
        # Preflight every destination before the first write so predictable
        # path/type/link validation failures cannot leave a partial update.
        _validate_atomic_write_target(args.output)
        if index_path is not None:
            _validate_atomic_write_target(index_path)
        _atomic_write_bytes(args.output, purpose_bytes)
        if index_path is not None and index_bytes is not None:
            _atomic_write_bytes(index_path, index_bytes)
    except PurposeCatalogError as error:
        print(f"package-purpose-zh: {error}", file=sys.stderr)
        return 2
    print(
        f"wrote {payload['package_count']} package purposes to {args.output} "
        f"for catalog {payload['catalog_version']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
