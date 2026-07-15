# Third-party notices

NexaWrt is GPL-2.0-only, but an experimental build may download and include
third-party components under their own licenses. Those components are not
relicensed under the NexaWrt license.

## Qualcomm NSS firmware

The optional `nss` flavor obtains the unmodified NSS firmware archive through
the pinned `qosmio/nss-packages` feed. The firmware archive version and hash
are controlled by that pinned feed revision. Redistribution is limited to
binary firmware used with Qualcomm Technologies chipsets and is subject to the
Qualcomm notice installed in the image at:

`/usr/share/licenses/nss-firmware/LICENSE.md`

The `official` flavor does not enable or include this NSS firmware package.

For an experimental NSS CI artifact, the repository-level notice and the exact
firmware license notice are copied into the isolated `dist-nss/` staging
directory alongside the RAM-boot-only manifest and checksums. Their presence
does not grant approval to boot or flash the artifact on a real device.
