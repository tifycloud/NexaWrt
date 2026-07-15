# Security Policy

## Supported scope

NexaWrt is currently an early-stage, RAM-only validation project for the Xiaomi AX9000 single-large-UBI-v1 layout.

No persistent flash image is supported or published. `sysupgrade`, factory, raw UBI, MTD writes, bootloader environment changes, and partition migration are outside the supported scope.

## Reporting a vulnerability

Do not open a public issue for credentials, private keys, device backups, MAC addresses, serial numbers, or an exploit that could damage a device.

Use GitHub's private vulnerability reporting feature for this repository. Include:

- affected commit or release;
- device model and layout evidence with identifying values redacted;
- reproduction steps;
- whether persistent storage may be written;
- relevant logs with secrets removed.

Do not upload raw router backups. They may contain passwords, keys, calibration data, MAC addresses, serial numbers, and personal configuration.

## Safety boundary

A successful build or initramfs boot does not authorize flashing. Persistent installation requires a separate design, recovery proof, destructive testing on a spare device, and independent review.
