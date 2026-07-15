## Summary

Describe the change and why it is needed.

## Safety impact

- [ ] This change does not enable or perform persistent storage writes.
- [ ] This change does not generate or publish sysupgrade/factory/raw UBI images.
- [ ] This change does not include credentials, backups, MAC addresses, serial numbers, or private configuration.
- [ ] I reviewed changes to DTS, MTD, UBI, boot arguments, upgrade hooks, and release policy, if applicable.

## Validation

- [ ] `./tests/test_static.sh`
- [ ] Clean OpenWrt prepare/patch validation, if build inputs changed
- [ ] Real-device testing was not performed, or its exact scope is documented below

## Test notes

Provide commands, logs, and known limitations. Redact identifying or secret values.
