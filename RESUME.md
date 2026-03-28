# Resume Instructions — GC2607 Camera on Fedora 43

## Current State (2026-03-28) — WORKING

Camera starts automatically at boot via systemd service. No manual commands needed.

- **Systemd service**: `gc2607-camera.service` (enabled, starts at boot)
- **Processing**: `gc2607_virtualcam.py` at `/opt/gc2607/`
- **Virtual camera**: `/dev/video50` ("GC2607 Camera") — visible in all apps
- **Features**: auto white balance (per-frame gray-world), auto exposure, sRGB gamma correction
- **Output**: 960x540 @ ~16fps

## What Happens at Boot

1. systemd starts `gc2607-camera.service`
2. `gc2607-service.sh` loads kernel modules, configures CSI2 formats and media pipeline
3. `gc2607_virtualcam.py` starts — captures raw Bayer, demosaics, applies WB/AE/gamma, writes to v4l2loopback
4. `gc2607-restart-wireplumber.sh` waits for user login, restarts wireplumber so PipeWire sees the camera
5. Wireplumber rule hides raw IPU6 nodes — apps only see "GC2607 Camera"

## After Fedora Kernel Updates

DKMS automatically rebuilds both modules. Just reboot into the new kernel.

Check status: `dkms status`

If DKMS fails (check `journalctl -u dkms`):
```bash
cd ~/dev/gc2607-v4l2-driver
sudo ./gc2607-install.sh
sudo reboot
```

## If Camera Stops Working

```bash
# Check service
sudo systemctl status gc2607-camera.service
journalctl -u gc2607-camera.service -n 30

# Restart service
sudo systemctl restart gc2607-camera.service
systemctl --user restart wireplumber

# If modules missing (kernel update)
cd ~/dev/gc2607-v4l2-driver
sudo ./gc2607-install.sh && sudo reboot
```

## Re-install Service (after script changes)

```bash
cd ~/dev/gc2607-v4l2-driver
sudo ./gc2607-setup-service.sh
```

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| `gc2607_virtualcam.py` | `/opt/gc2607/` | Real-time demosaic + auto-WB + auto-AE + gamma |
| `gc2607-service.sh` | `/opt/gc2607/` | Loads modules, configures pipeline, starts virtualcam |
| `gc2607-restart-wireplumber.sh` | `/opt/gc2607/` | Restarts wireplumber for PipeWire detection |
| `.python-path` | `/opt/gc2607/` | Saved Python path (written by setup script) |
| `gc2607-camera.service` | `/etc/systemd/system/` | Systemd unit file |
| `50-hide-ipu6-raw.conf` | `~/.config/wireplumber/` | Hides raw IPU6 nodes from PipeWire |
| `gc2607-install.sh` | repo | Builds/installs kernel modules for current kernel |
| `gc2607-setup-service.sh` | repo | One-time service installation |

## Known Limitations

- Output is 960x540 (half of 1920x1080) due to 2x2 Bayer demosaic
- ~16 fps (Python/numpy processing)
- Requires `numpy` and `pyfakewebcam` Python packages
