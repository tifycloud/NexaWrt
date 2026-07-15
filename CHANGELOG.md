# Changelog

All notable NexaWrt changes will be documented here.

## Unreleased

### Added

- Initial reproducible OpenWrt build framework.
- Xiaomi AX9000 single-large-UBI-v1 target configuration.
- Initramfs-only release policy; persistent firmware images are disabled.
- Fail-closed AX9000 upgrade hooks, RAM-only kernel command line override, and a read-only persistent MTD description.
- Persistent-write utilities are excluded from the resolved RAM-test image.
- Read-only router backup and layout validation tooling.
- Pinned OpenWrt v25.12.5 source and feed revisions.
- Static safety, backup guard, and release policy tests.
- GitHub Actions build and release workflows.

### Safety status

- No persistent installation is supported.
- No sysupgrade or factory image is generated or released.
- UART, bootloader visibility, recovery, and real-device RAM boot validation remain required.
