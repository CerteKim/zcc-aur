# SC8180X VPU (IRIS1) firmware

`venus.mbn` is the video VPU firmware for the Xiaomi Book S 12.4 (SC8180X),
extracted from the Windows driver package that ships on this machine.  The
device tree node `&venus` names it via `firmware-name`.

## Provenance

Source on the Windows partition (`/dev/nvme0n1p3`, NTFS, mounted read-only):

```
/Windows/System32/qcvss8180.mbn                       <- what this file is
/Windows/System32/DriverStore/FileRepository/qcdx8180.inf_arm64_678d3266ccd81904/qcvss8180.mbn
/Windows/System32/DriverStore/FileRepository/qcdx8180.inf_arm64_5219c639d4d51d02/qcvss8180.mbn
```

| file | date | QC_IMAGE_VERSION_STRING | md5 |
|---|---|---|---|
| `venus.mbn` (this file, from 2025 driver) | 2025-07-20 | `VIDEO.IR.1.2-00079-PROD-2` | `d99528d5010d9e8ed71c4276ddc0bb1c` |
| older 2022 driver copy | 2022-04-01 | `VIDEO.IR.1.2-00042-PROD-1` | `6909a826800cf68d4bc82e05c10bc132` |

Both are ELF32 ARM images with program headers and no section headers, i.e. the
standard format `qcom_mdt_load()` expects (the `NULL` program headers carry the
Qualcomm hash table/signature).

## Install

`/lib/firmware` needs root, so this is a manual step:

```
sudo install -Dm644 firmware/qcom/sc8180x/venus.mbn /lib/firmware/qcom/sc8180x/venus.mbn
```

## Notes

* `IR.1.2` is the IRIS1 generation, which is what the SC8180X VPU is; the
  `VIDEO.VE.*` images (`venus-*.mbn`) are the older AR50 firmware and
  `VIDEO.VPU.*` (`vpu/vpu20_p4.mbn`) is the SM8250 IRIS1 image.  Upstream is
  explicit that the SM8250 image is **not** compatible with other Gen1 SoCs, so
  this per-SoC file is what the node must point at.
* This is proprietary Qualcomm firmware taken from the local Windows install.
  It is staged here for the bring-up; do not publish it.
