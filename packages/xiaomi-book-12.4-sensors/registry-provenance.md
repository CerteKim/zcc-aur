# Provenance of the SSC sensor registry shipped by xiaomi-book-12.4-sensors

## What it is

`/usr/share/qcom/sc8180x/XIAOMI/BOOK124/sensors/` contains the *Sensors Service
Core* (SSC) registry for this board: the per-sensor configuration the SLPI needs
before it will report anything. Without it `hexagonrpcd` starts, the FastRPC
channel comes up, and every sensor request is answered with "registry sensor
unavailable" - the accelerometer simply never appears.

Two halves:

| Directory | Contents |
|---|---|
| `sensors/config/*.json` | per-sensor JSON configs (icm4x6xx accel/gyro, stk3a5x ambient light/proximity, ak991x mag, plus the `default_sensors`, `sns_amd`, `sns_gyro_cal`, `sns_rmd`, `sns_rotv` meta entries) |
| `sensors/registry/*` | the registry entries hexagonrpcd reads; most are JSON, some have no extension (`.accel`, `.gyro`, `.fac_cal.bias`, ...) |

## Where it comes from

The Windows installation on this machine (`\Windows\System32\DriverStore` +
the sensor registry keys under `HKLM\...\Sensors`), normalised into this
layout by `sscregistrygen` (a small tool that walks the vendor registry and
writes one file per sensor). It is vendor data - the same category as the
firmware blobs in `xiaomi-book-12.4-firmware` - so it is **not** tracked by
git: the package downloads/uses a tarball generated locally by

    ./scripts/make-sensors-registry-tarball.sh

from `~/qcom-slpi/root/sensors/` (the working copy kept from the bring-up) or
from an already-installed `/usr/share/qcom/sc8180x/XIAOMI/BOOK124/sensors/`.

## Regenerating

1. Put the extracted tree in place (`~/qcom-slpi/root/sensors/{config,registry}`);
2. `./scripts/make-sensors-registry-tarball.sh` → writes
   `packages/xiaomi-book-12.4-sensors/xiaomi-book-12.4-sensors-registry-<ver>.tar.zst`
   and prints its sha256 (paste it into the PKGBUILD);
3. `./scripts/build.sh xiaomi-book-12.4-sensors`.

The registry is read-only data: hexagonrpcd only reads it, and the SLPI writes
its calibration back through the FastRPC channel, not into these files.
