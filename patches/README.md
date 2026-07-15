# Patch policy

These patches apply only to the exact OpenWrt commit recorded in
`manifests/upstream.lock`.

- `001-*` keeps the project-only `single-large-UBI-v1` partition description,
  overrides the AX9000 kernel command line with `root=/dev/ram0`, and exposes
  only the distinct `xiaomi_ax9000_single_ubi` RAM-test profile. The profile
  marks the merged persistent MTD partition read-only, removes `mtd`,
  `uboot-envtools`, and `ubi-utils` (including the NAND default dependencies
  that would otherwise force `ubi-utils` back into the image), and clears
  `IMAGES` and `ARTIFACTS` so it cannot emit factory, sysupgrade, or persistent
  UBI images.
- `002-*` makes `platform_check_image`, `platform_pre_upgrade`, and
  `platform_do_upgrade` fail closed for `xiaomi,ax9000`. The AX9000 upgrade
  path performs no NAND/UBI formatting, bootloader-environment writes, or
  persistent image installation.

The current release policy is **RAM-only**: boot the initramfs image without
writing MTD, UBI, or U-Boot environment state. A Linux DTS partition change
alone does not update U-Boot's partition table or UBI scan range.

## Partition-size decision

The custom partition length is deliberately `0x0e800000`, matching the prior
read-only observation from the target router. It is not the `0x0ee80000`
mechanical sum of the two upstream fixed partitions. Never enlarge it without
fresh backup evidence confirming the real MTD offset, size, and erase geometry.

Any future persistent-upgrade design must be proposed and reviewed in a
separate RFC. That RFC must include verified UART recovery, complete backups,
bootloader visibility of the full UBI range, power-loss behavior, wear-leveling
assumptions, image compatibility/versioning, and an explicit rollback plan.
Until such an RFC is accepted and implemented, persistent flashing remains
unsupported and blocked.

The removal of the two NAND `ubi-utils` dependencies is intentionally global
inside the patched OpenWrt source tree, but the repository gate permits exactly
one selected device: this AX9000 RAM-test profile. Before adding any second
NAND device, replace this single-target shortcut with a device-scoped policy.

Do not refresh these patches against a newer OpenWrt revision without reviewing
the upstream AX9000 DTS, image recipe, `platform.sh`, and NAND upgrade library.
