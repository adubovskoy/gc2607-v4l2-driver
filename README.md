# GC2607 Camera Driver for Arch Linux

V4L2 driver + userspace ISP + systemd service that makes the **GalaxyCore
GC2607** sensor behind Intel IPU6 work as a regular webcam on Arch Linux
(and Arch-based distros like EndeavourOS, Manjaro, CachyOS).

After install the camera shows up as **"GC2607 Camera"** in any app that
uses PipeWire or plain V4L2 — GNOME Camera, Chromium, Firefox, OBS Studio,
Zoom, Slack, Google Meet, Telegram, etc.

> This is the Arch-Linux fork of [abbood/gc2607-v4l2-driver](https://github.com/abbood/gc2607-v4l2-driver)
> plus [PR #4](https://github.com/abbood/gc2607-v4l2-driver/pull/4) (DKMS
> + C ISP + systemd service). The upstream install scripts target Fedora
> (dnf, `/usr/src/kernels/<ver>`, xz-compressed modules); this fork ports
> them to pacman, `/lib/modules/<ver>/build`, and zstd.

## Supported hardware

| Thing | Value |
|---|---|
| Sensor | GalaxyCore GC2607 (chip ID 0x2607) |
| Platform | Intel IPU6 (Meteor Lake and later) |
| Reference laptop | Huawei MateBook Pro VGHH-XX |
| Format | 10-bit Bayer GRBG (SGRBG10) |
| Native resolution | 1920×1080 @ 30 fps |
| Virtual output | YUYV 960×540 @ 30 fps on `/dev/video50` |
| ACPI HID | `GCTI2607` |

## What gets installed

```
gc2607 sensor (SGRBG10 raw 10-bit Bayer)
  → Intel IPU6 CSI2 0
  → Intel IPU6 ISYS Capture 0  (/dev/videoN)
  → gc2607_isp                 (C: demosaic + auto-WB + auto-AE + sRGB gamma)
  → v4l2loopback /dev/video50  ("GC2607 Camera", YUYV 960x540)
  → PipeWire                   → camera apps
```

Two kernel modules:

- **`gc2607.ko`** — the sensor V4L2 subdev driver
- **`ipu-bridge.ko`** (patched) — adds `GCTI2607` to the IPU sensor table
  so IPU6 knows how to wire the sensor into the media pipeline

One userspace daemon:

- **`gc2607_isp`** — C program that reads Bayer from the IPU6 capture
  node, runs gray-world white balance + auto-exposure + sRGB gamma via
  a per-channel LUT, and writes YUYV into the v4l2loopback device
  (~4–5 % CPU on an Intel Core Ultra, vs. ~43 % for the Python version).

Plus a systemd service (`gc2607-camera.service`) that wires it all up at
boot, and a WirePlumber rule that hides the raw IPU6 sources so apps pick
the processed virtual camera.

## Install

### 1. Prerequisites

```bash
sudo pacman -S --needed base-devel linux-headers dkms zstd curl \
    v4l-utils v4l2loopback-dkms \
    gstreamer gst-plugins-base gst-plugins-good
```

### 2. Clone and build

```bash
git clone https://github.com/adubovskoy/gc2607-v4l2-driver.git
cd gc2607-v4l2-driver
make              # builds gc2607.ko and gc2607_isp
```

### 3. Install the kernel modules

You have two options. Pick **one**.

#### Option A: DKMS (recommended — survives kernel upgrades)

```bash
sudo ./dkms-setup.sh
```

This registers two DKMS packages (`gc2607` and `ipu-bridge-gc2607`). On
every kernel upgrade pacman runs the DKMS hooks and both modules rebuild
automatically — no manual step after `pacman -Syu`.

Verify:

```bash
dkms status
# gc2607/1.0, 6.19.13-arch1-1, x86_64: installed
# ipu-bridge-gc2607/1.0, 6.19.13-arch1-1, x86_64: installed
```

#### Option B: manual install (no kernel-update rebuild)

```bash
sudo ./gc2607-install.sh
```

This builds both modules once for the running kernel and installs them
under `/lib/modules/<ver>/`. After every `pacman -Syu` that bumps the
kernel you'll have to re-run it. Backups of the original `ipu-bridge`
land in `~/gc2607-backups/`.

To roll back:

```bash
sudo ./gc2607-install.sh revert
```

### 4. Install the systemd service (auto-start virtual camera)

```bash
sudo ./gc2607-setup-service.sh
```

This:

- Copies `gc2607_isp` and the service scripts to `/opt/gc2607/`
- Installs `gc2607-camera.service` and enables it
- Drops a WirePlumber rule at `~/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf`
  that disables the raw v4l2 IPU6 device nodes and the libcamera-backed
  GC2607 so camera apps see only the processed `/dev/video50`

### 5. Reboot

```bash
sudo reboot
```

After reboot:

```bash
# Service should be running
systemctl status gc2607-camera.service

# /dev/video50 should exist, labelled "GC2607 Camera"
v4l2-ctl --list-devices

# One quick test capture
ffmpeg -f v4l2 -i /dev/video50 -frames:v 1 -y /tmp/test.jpg
```

Open any camera app and pick **GC2607 Camera**.

## Usage notes

- The service uses **lazy activation** — `gc2607_isp` only pulls frames
  from the IPU6 when an app actually opens `/dev/video50`. Idle cost is
  essentially zero.
- The pipeline is 180° rotated in software (free, done during the YUYV
  write). If your mount is upside-down, remove the rotation in
  `gc2607_isp.c`.
- External USB webcams are **not** affected by the WirePlumber hide rule
  (it matches only `v4l2_device.pci-*` and the one specific IPU6
  libcamera device). Both will show up side by side.
- White balance is gray-world + per-frame, with no manual offsets. If
  the scene is heavily monochromatic the balance may drift; this is
  normal for gray-world.

## Troubleshooting

```bash
# Service / pipeline
journalctl -u gc2607-camera.service -n 50

# Was the sensor probed?
dmesg | grep -iE 'gc2607|GCTI2607'

# Is the bridge patched?
strings "$(modinfo -n ipu_bridge)" | grep GCTI2607

# Does PipeWire see the processed camera?
wpctl status | grep -iA1 video
```

Common issues:

- **"GC2607 Camera" missing after reboot** — `systemctl status
  gc2607-camera.service`; if `intel_ipu6` failed to probe, the service
  can't set up the CSI2 pipeline. Full log lives in journalctl.
- **Camera appears but shows green tint / garbled colours** — your app
  likely picked the raw libcamera source instead of `/dev/video50`.
  Re-run `sudo ./gc2607-setup-service.sh` and restart the app; the
  WirePlumber rule should hide the libcamera entry.
- **Kernel just upgraded, module missing** — if you used manual install
  (Option B), re-run `sudo ./gc2607-install.sh`. If you used DKMS,
  check `dkms status` — rebuilds can fail e.g. when `linux-headers` for
  the new kernel isn't installed yet.
- **DKMS build fails on `ipu-bridge-gc2607`** — the pre-build script
  fetches matching `ipu-bridge.c` from kernel.org. Make sure the machine
  has internet access when pacman runs the DKMS hook.
- **Suspend hangs / `-EBUSY` on resume** — you're probably on an old
  build of `gc2607.ko` without `SET_SYSTEM_SLEEP_PM_OPS`. Rebuild from
  this branch (or `dkms install --force`).

## Uninstall

```bash
# Stop the service
sudo systemctl disable --now gc2607-camera.service
sudo rm -f /etc/systemd/system/gc2607-camera.service
sudo rm -f /usr/lib/systemd/system-sleep/gc2607
sudo rm -rf /opt/gc2607
sudo rm -f /etc/udev/rules.d/99-gc2607-camera.rules
rm -f ~/.config/wireplumber/wireplumber.conf.d/50-hide-ipu6-raw.conf

# If installed via DKMS
sudo dkms uninstall gc2607/1.0 --all
sudo dkms remove    gc2607/1.0 --all
sudo dkms uninstall ipu-bridge-gc2607/1.0 --all
sudo dkms remove    ipu-bridge-gc2607/1.0 --all
sudo rm -f /etc/depmod.d/ipu-bridge-gc2607.conf
sudo depmod -a

# If installed manually
sudo ./gc2607-install.sh revert
```

## Differences from upstream

- `gc2607-install.sh` / `dkms-setup.sh` use **pacman + zstd +
  `/lib/modules/<ver>/build`** instead of dnf + xz + `/usr/src/kernels`.
- `gc2607-restart-wireplumber.sh` picks the desktop user by scanning
  `/run/user/` for **uid >= 1000** instead of relying on `logname` /
  `who`, so it no longer tries to `su -` into the display-manager's
  greeter account (e.g. `plasmalogin` on KDE) which has a nologin shell.
- The WirePlumber rule also disables the **libcamera-backed GC2607**
  (`libcamera_device.version`), not just the PCI v4l2 nodes — otherwise
  some apps pick the libcamera source and show raw Bayer.
- Build artifacts (`*.ko`, `*.o`, `.*.cmd`, `Module.symvers`, `gc2607_isp`)
  are gitignored rather than tracked.

## Credit

- Original out-of-tree driver: [**abbood/gc2607-v4l2-driver**](https://github.com/abbood/gc2607-v4l2-driver)
- DKMS, C ISP, systemd service, suspend support: [**farhanferoz** (PR #4)](https://github.com/abbood/gc2607-v4l2-driver/pull/4)
- Arch Linux port: [**adubovskoy**](https://github.com/adubovskoy/gc2607-v4l2-driver)
- Hardware identification: [yegor-alexeyev](https://github.com/yegor-alexeyev) — suggested the MateBook Pro 2024 VGHH-XX uses GC2607 in [intel/ipu6-drivers#399](https://github.com/intel/ipu6-drivers/issues/399#issuecomment-3707318638)

## License

GPL-2.0, matching the Linux kernel.
