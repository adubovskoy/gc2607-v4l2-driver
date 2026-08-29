# Adapting to your laptop

The fixes here were developed on one Meteor Lake machine. GC2607 boards
differ in three ways; each is handled without recompiling where
possible.

## 1. Sensor orientation (flipped / mirrored image)

`gc2607_isp` accepts a third CLI argument, passed through by
`gc2607-service.sh` from the `GC2607_ROTATION` environment variable:

| Value | Effect | Use when |
|---|---|---|
| `none` | direct mapping | sensor upright, not mirrored |
| `hflip` (default) | horizontal flip only | upright but mirrored (this machine) |
| `rot180` | full 180° rotation | sensor mounted inverted (upstream author's machine) |

Set it in the systemd unit (no rebuild):

```ini
# /etc/systemd/system/gc2607-camera.service
[Service]
Environment=GC2607_ROTATION=none
```

then `sudo systemctl restart gc2607-camera`.

Quick check: `ffplay -f v4l2 -input_format yuyv422 -video_size 960x540 /dev/video50`
— if text/objects are upside down or mirrored, switch the mode.

## 2. CSI2 port / ISYS capture node

`gc2607-service.sh` auto-detects both from the media topology, so no
editing is needed for ports other than `CSI2 0`. If detection ever
fails, look at the actual wiring:

```bash
media-ctl -d /dev/media0 -p | grep -E "entity [0-9]+:"
# e.g. "entity 349: gc2607 3-0037" → follow its link to the CSI2 port
```

The service logs the resolution:
`[gc2607] Sensor wired to "Intel IPU6 CSI2 4"`.

## 3. Frame rate vs. low-light exposure

The driver caps `VTS` at 1125 (~29 fps) and the ISP caps exposure at 900
lines, pushing AE to analogue gain in dim scenes. Trade-offs:

- **You want more fps** (e.g. sensor supports higher): raise `VTS` in
  `gc2607.c` (`GC2607_VTS`) and the register pair `0x0220/0x0221`
  (`VTS`), keeping `EXPOSURE_MAX = VTS - 1` and
  `EXPOSURE_DEFAULT ≤ EXPOSURE_MAX` (a default above the cap makes the
  sensor fail to probe with `-ERANGE`).
- **You want cleaner low-light image and accept ~16 fps**: revert to
  `VTS=2003` (`0x07d3`) and raise the ISP `EXPOSURE_MAX` back to 2002.

```bash
# Measure achieved frame rate after any change:
journalctl -u gc2607-camera.service -n 100 | grep "frames |"
# 150 frames every ~5 s ≈ 30 fps; every ~9 s ≈ 16 fps
```

## 4. Other sensors (OVTI, etc.)

The same diagnosis path (`docs/diagnosis.md`) applies to any IPU6
sensor: confirm the ACPI HID, add it to `ipu-bridge.c`
(`IPU_SENSOR_CONFIG("HID", nlanes, link_freq)`) if missing, and make
sure a userspace ISP exists for the raw Bayer output. Sensor-specific
register tables (`gc2607_1080p_30fps_regs[]`) must come from the
vendor's reference driver.
