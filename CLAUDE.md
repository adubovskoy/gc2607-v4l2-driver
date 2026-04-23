# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build everything (kernel module + userspace ISP)
make

# Build only the kernel module
make modules

# Build only the userspace ISP program
make isp

# Clean build artifacts
make clean

# Install modules (gc2607 + patched ipu-bridge) for current kernel
sudo ./gc2607-install.sh

# Install and enable the camera systemd service (one-time setup)
sudo ./gc2607-setup-service.sh

# Check camera service status
sudo systemctl status gc2607-camera.service
journalctl -u gc2607-camera.service

# Check driver probe status
dmesg | grep gc2607
```

## Project Overview

V4L2 Linux kernel driver for the GalaxyCore GC2607 camera sensor, ported from the Ingenic T41 platform (MIPS) to Intel IPU6 on x86_64. The camera starts automatically at boot via a systemd service.

**Target hardware:** Huawei MateBook Pro VGHH-XX with GC2607 sensor on I2C bus 5 at address 0x37.

## Architecture

### Full Pipeline

```
gc2607 sensor (SGRBG10 raw 10-bit Bayer)
  → Intel IPU6 CSI2 0
  → Intel IPU6 ISYS Capture 0 (/dev/videoN)
  → gc2607_isp (C: demosaic + auto-WB + auto-exposure + gamma via per-channel LUT)
  → v4l2loopback /dev/video50 ("GC2607 Camera", YUYV 960x540)
  → PipeWire → camera apps (GNOME Camera, Chrome, OBS, etc.)
```

### Userspace ISP (`gc2607_isp.c`)

A lightweight C program that replaced the original Python virtualcam (`gc2607_virtualcam.py`). Uses ~4-5% CPU (down from ~43% with Python/NumPy).

**Key design: per-channel LUT.** All per-pixel operations (black level subtract → WB gain → brightness → S-curve contrast → sRGB gamma) are composed into three 1024-entry LUTs (one per R/G/B channel), recomputed once per frame. Per-pixel work is a single table lookup per channel.

- **V4L2 MMAP capture** — direct kernel buffers, no subprocess overhead
- **Gray-world auto white balance** — no manual offsets, pure `g_mean/r_mean` and `g_mean/b_mean`
- **Hardware + software auto-exposure** — software brightness multiplier for fast response, hardware exposure/gain adjustment for range
- **YUYV output** — writes directly to v4l2loopback, no intermediate RGB conversion library
- **180° rotation** — zero-cost via reverse iteration during output

### Why C ISP instead of Python or GStreamer?

- **GStreamer**: `bayer2rgb` only supports 8-bit Bayer and produces green tint from 10-bit data
- **Python/NumPy**: Works correctly but uses ~43% CPU due to interpreter overhead, multiple array passes, subprocess capture, and Python RGB→YUYV conversion
- **C with LUT**: All per-pixel math collapses into a single table lookup. Direct V4L2 MMAP avoids copy overhead. ~4-5% CPU on Intel Ultra 9.

### Driver (gc2607.c — single file, ~1000 lines)

The entire driver is in `gc2607.c`. Key sections by function:

- **Hardware constants** (lines 1-100): Register addresses, chip ID (0x2607), exposure/gain limits, 17-entry gain LUT
- **Register init table** `gc2607_1080p_30fps_regs[]` (lines ~158-296): 122-register sequence for 1080p30 mode
- **Power management** (lines ~318-428): INT3472 PMIC integration — regulators, clocks, reset GPIO pulse sequence (LOW→HIGH→LOW→HIGH with specific timing)
- **V4L2 pad ops** (lines ~435-525): Format enumeration/negotiation (SGRBG10, 1920x1080)
- **V4L2 controls** (lines ~729-751): Link frequency (336 MHz), pixel rate (134.4 MHz), exposure (4-2002), analogue gain (LUT index 0-16)
- **Probe/remove** (lines ~900-1006): ACPI matching on "GCTI2607", async subdev registration, chip ID verification

### Key Design Decisions

- **ACPI matching** (not DT): Uses HID "GCTI2607" since target is x86_64 laptop
- **INT3472 PMIC**: Power/reset/clock managed through Intel's discrete PMIC driver, not direct GPIO
- **Gain via LUT**: Analogue gain uses a 17-entry lookup table (index 0-16) that writes to 4 registers simultaneously, matching the reference driver's approach
- **No hardware WB**: Sensor has no white balance registers; WB is done per-frame in `gc2607_isp` using gray-world algorithm
- **Auto-exposure in software**: `gc2607_isp` measures green channel mean and adjusts software brightness + sensor hardware exposure/gain to maintain target brightness
- **IPU6 bridge patch required**: The stock `ipu_bridge.ko` doesn't know about GC2607. A modified version with `IPU_SENSOR_CONFIG("GCTI2607", 1, 336000000)` must be installed (see `0001-media-ipu-bridge-*.patch`)
- **Wireplumber rule hides raw IPU6 nodes**: Without this, camera apps try to use raw IPU6 devices instead of the virtual camera. Config at `~/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf`

### Reference Driver

`reference/gc2607.c` is the original Ingenic T41 driver that this port is based on. It uses platform-specific APIs (`tx-isp-common.h`, `private_i2c_transfer()`) that were replaced with standard Linux V4L2/I2C/GPIO APIs.

## Hardware Details

| Parameter | Value |
|-----------|-------|
| Sensor | GC2607 (chip ID 0x2607) |
| I2C | Bus 5, address 0x37 |
| MIPI CSI-2 | 2 lanes, 672 Mbps/lane (link_freq=336 MHz) |
| Format | SGRBG10 (10-bit Bayer GRBG), use pixelformat=BA10 on video device |
| Resolution | 1920x1080@30fps (output 960x540 after 2x2 demosaic) |
| Frame timing | HTS=2048, VTS=1335 |
| Registers | 16-bit addresses, 8-bit values |
| ACPI device | GCTI2607:00 at \_SB_.PC00.LNK0 |
| PMIC | INT3472:01 (discrete), provides regulator + reset GPIO + clock |

## Key Files

- `gc2607_isp.c` — **Userspace C ISP**: demosaic + auto-WB + auto-AE + gamma via per-channel LUT (~4-5% CPU)
- `gc2607_virtualcam.py` — Legacy Python ISP (fallback if C ISP not built)
- `dkms-setup.sh` — Set up DKMS for automatic module rebuilds on kernel updates (one-time setup)
- `gc2607-install.sh` — Manually build and install both modules (fallback if DKMS not set up)
- `gc2607-setup-service.sh` — Install systemd service for auto-start at boot (one-time setup)
- `gc2607-service.sh` — Service script: loads modules, configures pipeline, starts ISP (called by systemd)
- `gc2607-restart-wireplumber.sh` — Restarts wireplumber after ISP starts (called by systemd)
- `gc2607-start.sh` — Manual start (alternative to systemd service)
- `gc2607-reload.sh` — Hot-reload modules without reboot (when possible)
- `gc2607-test.sh` — Capture a single frame and convert to PNG
- `view_raw_wb.py` — Convert raw capture to PNG with gray world white balance

## After Kernel Updates (Arch Linux)

DKMS automatically rebuilds both modules (gc2607 + patched ipu-bridge) on kernel updates. No manual steps needed — just reboot into the new kernel after `pacman -Syu`.

To check DKMS status: `dkms status`

If DKMS wasn't set up or the automatic rebuild fails:
```bash
sudo ./gc2607-install.sh   # manually rebuilds both modules
sudo reboot
```

To set up DKMS (one-time): `sudo ./dkms-setup.sh`

## Common Pitfalls

- **Format mismatch on stream start**: Video device must use pixelformat=BA10 (not GB10) to match sensor's GRBG Bayer pattern
- **Reset sequence**: Reset GPIO must end de-asserted (HIGH) or sensor won't respond to I2C
- **Green tint in GStreamer**: GStreamer's `bayer2rgb` outputs green at 1.7x red/blue from 10-bit Bayer. Use `gc2607_isp` instead, which does proper demosaicing with per-frame WB
- **Media link must be enabled**: `media-ctl -l` command required before streaming (done by `gc2607-service.sh`)
- **CSI2 format must be set**: CSI2 pads default to 4096x3072; must set to 1920x1080 or streaming fails with broken pipe
- **Module compression (Arch)**: Arch uses zstd for kernel modules (`ipu-bridge.ko.zst`). `gc2607-install.sh` compresses the built module with `zstd` before installing. On distros that still use xz, compress with `xz --check=crc32` (default CRC64 fails to load with `decompression failed with status 6`).
- **Home directory permissions**: systemd services may not access home dirs (mode 700). Scripts are installed to `/opt/gc2607/`
- **PipeWire/wireplumber**: Must restart wireplumber after v4l2loopback loads so camera apps see the device. Must also hide raw IPU6 nodes via wireplumber rule or apps pick wrong device
- **Python path** (legacy fallback only): `gc2607-setup-service.sh` finds a Python with `numpy` + `pyfakewebcam` at install time and saves to `/opt/gc2607/.python-path`. Only used if `gc2607_isp` binary is not available
- **Color tinge with manual WB offsets**: Never add manual R/G/B offset multipliers to the WB algorithm. Pure gray-world (`g_mean/r_mean`, `g_mean/b_mean`, green=1.0) produces correct colors. Manual offsets cause scene-dependent color shifts
