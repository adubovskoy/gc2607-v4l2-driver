# Diagnosis: why the camera didn't work, and how we found out

This document is the debugging trail that produced the fixes in this
repo. If you have a GC2607 (or any other IPU6 sensor) laptop that shows
no camera, work through the checks below in order — each step's
conclusion drove the next.

Symptom on the reference machine: **no camera in any app**; `v4l2-ctl`
on the IPU6 capture node failed with `VIDIOC_STREAMON: Link has been
severed`.

## Step 1 — Is the hardware there at all?

IPU6 (Meteor Lake integrated camera) registers dozens of V4L2 nodes even
with no sensor attached, so a long `/dev/video*` list proves nothing by
itself.

```bash
# Are the IPU6 kernel drivers loaded?
lsmod | grep -E "intel_ipu6|ipu_bridge"
# Does the IPU6 PCI device authenticate?
journalctl -k -b | grep -i ipu6
#   expect: "CSE authenticate_run done", "IPU6 in secure mode"
```

On this machine: drivers loaded, CSE authenticated, firmware
`ipu6epmtl_fw.bin` present. Hardware side OK — the problem was upstream
of the capture node.

## Step 2 — Which sensors does ACPI actually declare?

Meteor Lake sensors are ACPI devices. Enumerate them and check whether
the kernel bound a driver:

```bash
ls /sys/bus/acpi/devices/ | grep -iE "OVTI|GCTI|INT3472"
for d in /sys/bus/acpi/devices/OVTI* /sys/bus/acpi/devices/GCTI*; do
    [ -d "$d" ] && echo "$(basename $d): driver=$(readlink $d/driver 2>/dev/null | xargs basename 2>/dev/null)"
done
```

Findings on this machine:

- `OVTI01AS` (IR) and `OVTI13B1` (RGB) — both `driver: NONE`, and their
  ACPI `_STA` returned 0 (BIOS-disabled; they show up as `LNK1`/`LNK2`
  pseudo-devices under `\_SB_.PC00`).
- **`GCTI2607`** — this is the real RGB sensor (GalaxyCore GC2607), and
  it was the one with no driver support at all.

Two sensors being firmware-disabled while a third exists but is
unbound is a common pattern on MTL laptops. Don't assume the OVTI HIDs
are your camera — check all of them.

## Step 3 — Why isn't the sensor in the media graph?

```bash
media-ctl -d /dev/media0 -p | grep "entity "
```

On a working setup you expect the sensor subdev (e.g. `gc2607 3-0037`)
at the sink of a CSI2 entity. Here the graph contained only ISYS
Capture nodes and CSI2 subdevs — no sensor entity, so the CSI2 sink pad
had nothing connected: hence "Link has been severed".

The missing link is `ipu_bridge`'s job: it reads the ACPI tables, finds
`GCTI2607`, looks it up in its supported-sensor table, creates the I2C
client and wires the media pipeline. The upstream `ipu-bridge.c` table
did not contain `GCTI2607`, so nothing happened.

```bash
# Confirm: search the running kernel's bridge table
grep -c GCTI2607 /lib/modules/$(uname -r)/updates/dkms/ipu-bridge.ko 2>/dev/null || echo 0
```

## Step 4 — Sensor present but capture still fails

After adding `IPU_SENSOR_CONFIG("GCTI2607", 1, 336000000)` to
`ipu-bridge.c`, the sensor probes (kernel log: `Read chip ID: 0x2607`,
`probe successful`) and the media graph shows `gc2607 3-0037`.

Two things still blocked streaming:

1. **Wrong CSI2 port.** The reference driver hardcoded `CSI2 0`; this
   board wires the sensor to **CSI2 4**. The service script now derives
   the port from the live topology instead (see `gc2607-service.sh`).
2. **No userspace ISP.** IPU6 exposes raw 10-bit Bayer only. Without
   `icamerasrc`/libcamera-HAL on Arch, nothing produces a viewable
   image. The C `gc2607_isp` (this repo) fills that gap: 2×2 Bayer
   binning, gray-world AWB, auto-exposure, sRGB gamma → YUYV into
   v4l2loopback.

## Step 5 — Why the image was flipped / slow (post-install)

- **Orientation**: the upstream ISP hardcoded a 180° rotation for the
  author's inverted mount. On this machine the sensor is upright but
  mirrored → only a horizontal flip was needed. Now configurable
  (`none|hflip|rot180`, see README).
- **16 fps instead of 30**: the sensor driver set `VTS=2003`
  (frame length) for "1.5x exposure", which at the sensor's ~67.2
  Mpix/s data rate yields ~16 fps. Cutting VTS to 1125 restores
  ~29 fps; dim-scene brightness is handled by AE raising analogue gain
  (exposure is capped at 900 lines so the frame rate holds).

```bash
# Verify frame rate post-fix (service running, then):
timeout 10 ffmpeg -f v4l2 -input_format yuyv422 -video_size 960x540 \
    -i /dev/video50 -t 8 -f null -
journalctl -u gc2607-camera.service -n 50 | grep "frames |"
```

## TL;DR decision chain

```
no camera in apps
  └─ STREAMON "Link has been severed"
       └─ media graph has no sensor entity
            └─ ipu_bridge table lacks GCTI2607   → patch ipu-bridge.c
            └─ (sensor now in graph) but CSI2 port hardcoded wrong
                 → derive port from topology
            └─ raw Bayer, no userspace ISP       → build gc2607_isp
```
