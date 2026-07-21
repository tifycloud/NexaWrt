#!/usr/bin/env python3
"""Shared fail-closed policy for generated OpenWrt package records."""

from __future__ import annotations

HIGH_RISK_EXACT = frozenset(
    {
        "apk-mbedtls",
        "base-files",
        "busybox",
        "fstools",
        "fwtool",
        "kernel",
        "libc",
        "luci-base",
        "mtd",
        "opkg",
        "procd",
        "procd-seccomp",
        "procd-ujail",
        "ubus",
        "ubusd",
        "uci",
        "urandom-seed",
    }
)
HIGH_RISK_PREFIXES = (
    "apk-",
    "grub",
    "ipq-wifi-",
    "kexec",
    "opkg-",
    "trusted-firmware-",
    "u-boot",
    "uboot-",
)
SYSTEM_PREFIXES = (
    "base-files",
    "block-mount",
    "busybox",
    "firewall",
    "fstools",
    "init",
    "mtd",
    "netifd",
    "nftables",
    "odhcp",
    "procd",
    "ubus",
    "uci",
)
ADVANCED_SUFFIXES = ("-dbg", "-dev", "-src", "-static")
ALLOWED_ARCHITECTURES = {
    ("x86_64", "official"): frozenset({"x86_64", "noarch"}),
    ("xiaomi_ax9000", "official"): frozenset({"aarch64_cortex-a53", "noarch"}),
    ("xiaomi_ax9000", "nss"): frozenset({"noarch"}),
}

PACKAGE_SOURCES = frozenset({"official", "kiddin9"})


def blocked_reason_for(package: str) -> str:
    """Return the mandatory block reason, or an empty string when selectable."""
    lower = package.lower()
    if lower in HIGH_RISK_EXACT or lower.startswith(HIGH_RISK_PREFIXES):
        return "核心系统、引导或包管理组件不可由自定义构建请求直接选择。"
    if "firmware" in lower or lower.endswith("-fw"):
        return "设备固件包需按目标硬件审核，不能由通用组件目录直接选择。"
    if lower.startswith("bootloader-") or lower.endswith("-bootloader"):
        return "引导加载器组件不可由自定义构建请求直接选择。"
    return ""


def blocked_reason_for_record(
    package: str, source: str, *, duplicates_official: bool = False
) -> str:
    """Return the source-aware block reason for one catalog record."""
    reason = blocked_reason_for(package)
    if reason:
        return reason
    if source == "kiddin9":
        if duplicates_official:
            return "社区候选库未审核且与 OpenWrt 官方包同名，不允许覆盖官方来源或进入生产构建。"
        return "社区候选库未完成源码安全审核，不允许进入生产构建。"
    if source not in PACKAGE_SOURCES:
        return "包来源不在 NexaWrt 的允许列表中。"
    return ""


def risk_for(package: str, feed: str) -> str:
    """Return the mandatory risk label for a package/feed pair."""
    lower = package.lower()
    if feed == "kmods" or lower.startswith("kmod-") or lower.endswith(ADVANCED_SUFFIXES):
        return "advanced"
    if blocked_reason_for(package) or feed == "target" or lower.startswith(SYSTEM_PREFIXES):
        return "system"
    return "standard"


def allowed_architectures_for(target: str, flavor: str) -> frozenset[str]:
    """Return the exact architecture allow-list for a published shard."""
    try:
        return ALLOWED_ARCHITECTURES[(target, flavor)]
    except KeyError as error:
        raise ValueError(f"unsupported package shard architecture policy: {target}/{flavor}") from error
