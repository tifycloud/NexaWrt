# Contributing to NexaWrt

NexaWrt currently supports only the explicitly documented Xiaomi AX9000 single-large-UBI-v1 layout. Contributions must preserve the RAM-only safety boundary.

## Before submitting a change

1. Create a focused branch.
2. Do not add router backups, credentials, private keys, MAC addresses, serial numbers, or personal configuration.
3. Run:

   ```sh
   ./tests/test_static.sh
   ```

4. Explain any change to DTS, MTD, UBI, boot arguments, image recipes, upgrade hooks, or release policy.
5. State whether the change can write persistent storage.

## Changes requiring extra review

The following changes are blocked from ordinary pull requests and require a separate design review:

- enabling `sysupgrade`, factory, raw UBI, or other persistent images;
- changing MTD offsets or sizes;
- changing UBI volume IDs or names;
- adding U-Boot environment writes;
- adding third-party NSS/ECM acceleration stacks;
- adding a new device target;
- changing the RAM-only release policy.

## Commit style

Use short imperative subjects, for example:

```text
docs: clarify RAM-only testing boundary
build: pin OpenWrt feed revisions
ax9000: validate single-large-UBI runtime layout
```
