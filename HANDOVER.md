# Handover: GC2607 Camera Driver

**Date:** April 2, 2026
**Status:** **RUNNING** — C ISP at ~4-5% CPU, correct colors, auto WB + AE

## Current State

The camera is running via `gc2607_isp` (C program), replacing the previous Python virtualcam.

| Metric | Before (Python) | After (C ISP) |
|--------|-----------------|---------------|
| CPU usage | ~43% | ~4-5% |
| Memory | ~76 MB | ~20 KB |
| Color balance | Tinge (scene-dependent) | Neutral (pure gray-world) |
| Dependencies | Python + NumPy + pyfakewebcam | None (pure C + libc) |
| Startup WB convergence | ~30 seconds | Immediate |

## Architecture

```
gc2607 sensor (SGRBG10 raw 10-bit Bayer, 1920x1080)
  → V4L2 MMAP capture in gc2607_isp
  → Per-channel LUT ISP (black level → WB → brightness → S-curve → gamma)
  → YUYV 960x540 output to v4l2loopback /dev/video50
  → PipeWire → camera apps
```

**Key design:** All per-pixel operations are composed into 3 LUTs (1024 entries each, one per R/G/B channel), recomputed once per frame. Per-pixel work = one table lookup.

## What Was Fixed

### Color Tinge (Root Cause + Fix)
The previous Python virtualcam had manual WB offsets (`G_OFFSET=0.75`, `R_OFFSET=1.05`, `B_OFFSET=1.05`) and cross-talk reduction (`r -= 0.05*g`) that caused scene-dependent color shifts. **Fix:** Pure gray-world WB with NO offsets — same algorithm as `view_raw_wb.py` which always produced correct colors.

### CPU Usage (Root Cause + Fix)
Python/NumPy at 1080p30 requires ~15M float32 operations per frame across multiple array passes, plus subprocess capture overhead and Python RGB→YUYV conversion. **Fix:** C program with direct V4L2 MMAP, single-pass LUT processing, and direct YUYV output.

## Service Management

```bash
sudo systemctl status gc2607-camera.service   # check status
sudo systemctl restart gc2607-camera.service   # restart
sudo systemctl stop gc2607-camera.service      # stop
journalctl -u gc2607-camera.service            # view logs

# Re-install after code changes
cd ~/dev/gc2607-v4l2-driver
make isp
sudo systemctl stop gc2607-camera.service
sudo cp gc2607_isp /opt/gc2607/
sudo systemctl start gc2607-camera.service
```

## Key Files

| File | Purpose |
|------|---------|
| `gc2607_isp.c` | C ISP program (active) |
| `gc2607_virtualcam.py` | Python ISP (legacy fallback) |
| `gc2607.c` | V4L2 kernel driver |
| `gc2607-service.sh` | Service startup script |
| `gc2607-setup-service.sh` | One-time service installation |
| `view_raw_wb.py` | Reference for correct color output |

## ISP Parameters (in `gc2607_isp.c`)

| Parameter | Value | Notes |
|-----------|-------|-------|
| `BLACK_LEVEL` | 64 | Sensor hardware black level |
| `WB_SMOOTHING` | 0.85 | Temporal smoothing (0=instant, 1=frozen) |
| `AE_TARGET` | 100 | Target brightness (0-255 scale) |
| `AE_SMOOTHING` | 0.92 | Software AE temporal smoothing |
| `AE_INTERVAL_S` | 1.5 | Hardware exposure/gain update interval |

## Advice for Next Agent

- **DO NOT** add manual R/G/B offsets or cross-talk reduction to WB. Pure gray-world works correctly.
- If colors look wrong, check `BLACK_LEVEL` against actual sensor dark frame data.
- If a consistent color bias remains after pure gray-world WB, the correct fix is a 3x3 Color Correction Matrix (CCM) calibrated against a gray card, NOT manual channel offsets.
- The C ISP has a Python fallback — if `gc2607_isp` binary is missing, `gc2607-service.sh` falls back to `gc2607_virtualcam.py`.
