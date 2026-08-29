#!/bin/bash
#
# GC2607 Camera Service Script
# Called by systemd gc2607-camera.service at boot.
# Sets up the full pipeline and starts the Python virtualcam.
#

set -euo pipefail

SCRIPT_DIR="/opt/gc2607"
KVER="$(uname -r)"

log() { echo "[gc2607] $*"; }
die() { echo "[gc2607] ERROR: $*" >&2; exit 1; }

# ── Load Modules ────────────────────────────────────────────────────

log "Loading kernel modules..."
for mod in videodev v4l2-async ipu_bridge intel-ipu6 intel-ipu6-isys; do
    modprobe "$mod" 2>/dev/null || true
done
sleep 1

# Load gc2607
if ! grep -q "^gc2607 " /proc/modules; then
    if [ -f "/lib/modules/${KVER}/extra/gc2607.ko" ]; then
        modprobe gc2607
    elif [ -f "${SCRIPT_DIR}/gc2607.ko" ]; then
        insmod "${SCRIPT_DIR}/gc2607.ko"
    else
        die "gc2607.ko not found"
    fi
fi
sleep 2

# ── Verify Sensor ───────────────────────────────────────────────────

if ! grep -q "^gc2607 " /proc/modules; then
    die "gc2607 module not loaded"
fi

MEDIA_DEV=""
for dev in /dev/media*; do
    if media-ctl -d "$dev" --print-topology 2>/dev/null | grep -qi "gc2607"; then
        MEDIA_DEV="$dev"
        break
    fi
done

if [ -z "$MEDIA_DEV" ]; then
    die "GC2607 not in media topology"
fi
log "Sensor on $MEDIA_DEV"

# ── Configure Pipeline ──────────────────────────────────────────────

# The GC2607 sensor can be wired to any CSI2 port (varies by board —
# e.g. CSI2 0 on some units, CSI2 4 on others). Derive the wiring from
# the actual media topology instead of hardcoding a port.
TOPO="$(media-ctl -d "$MEDIA_DEV" --print-topology 2>/dev/null)" || true

CSI2_PORT="$(printf '%s\n' "$TOPO" \
    | grep '"Intel IPU6 CSI2 [0-9]":0 \[' \
    | grep -o '"Intel IPU6 CSI2 [0-9]"' | head -1)" || true
if [ -z "$CSI2_PORT" ]; then
    die "Could not find CSI2 port wired to GC2607"
fi
CSI2_NUM="$(printf '%s\n' "$CSI2_PORT" | grep -o 'CSI2 [0-9]' | grep -o '[0-9]' | tail -1)"
log "Sensor wired to $CSI2_PORT"

CAP_NAME="$(printf '%s\n' "$TOPO" | sed -n "/entity .*CSI2 ${CSI2_NUM} (/,/entity .*CSI2 /p" \
    | grep -o 'Intel IPU6 ISYS Capture [0-9]*' | head -1)" || true
if [ -z "$CAP_NAME" ]; then
    die "Could not find ISYS capture node on $CSI2_PORT"
fi

CAPTURE_DEV="$(printf '%s\n' "$TOPO" | grep -A3 "entity.*${CAP_NAME}" \
    | grep -o '/dev/video[0-9]*' | head -1)" || true
if [ -z "$CAPTURE_DEV" ]; then
    die "Could not resolve device node for ${CAP_NAME}"
fi
log "Capture device: ${CAPTURE_DEV} (${CAP_NAME})"

media-ctl -d "$MEDIA_DEV" -V "${CSI2_PORT}:0 [fmt:SGRBG10_1X10/1920x1080]"
media-ctl -d "$MEDIA_DEV" -V "${CSI2_PORT}:1 [fmt:SGRBG10_1X10/1920x1080]"
media-ctl -d "$MEDIA_DEV" -l "${CSI2_PORT}:1 -> \"${CAP_NAME}\":0[1]" 2>/dev/null
v4l2-ctl -d "$CAPTURE_DEV" --set-fmt-video=width=1920,height=1080,pixelformat=BA10

log "Pipeline configured"

# ── Load v4l2loopback ───────────────────────────────────────────────

if grep -q "^v4l2loopback " /proc/modules; then
    modprobe -r v4l2loopback 2>/dev/null || true
    sleep 1
fi

# Prefer /dev/video50 but fall back to whatever v4l2loopback grabs if 50 is
# already taken (e.g. by an external USB webcam that enumerated first).
modprobe v4l2loopback \
    devices=1 \
    video_nr=50 \
    card_label="GC2607 Camera" \
    exclusive_caps=1 \
    max_buffers=2 \
    || modprobe v4l2loopback \
        devices=1 \
        card_label="GC2607 Camera" \
        exclusive_caps=1 \
        max_buffers=2

# Discover the actual loopback device by card label — robust against
# v4l2loopback picking a different number when /dev/video50 is busy.
LOOP_DEV=""
for dev in /dev/video*; do
    drv=$(v4l2-ctl -d "$dev" --info 2>/dev/null | grep "Driver name" | awk -F': *' '{print $2}' | tr -d ' ')
    card=$(v4l2-ctl -d "$dev" --info 2>/dev/null | grep "Card type"  | awk -F': *' '{print $2}')
    if [ "$drv" = "v4l2loopback" ] && [ "$card" = "GC2607 Camera" ]; then
        LOOP_DEV="$dev"
        break
    fi
done

[ -z "$LOOP_DEV" ] && die "v4l2loopback device for GC2607 not found after modprobe"
log "v4l2loopback at $LOOP_DEV"

# ── Start C ISP (or fallback to Python virtualcam) ─────────────────

# Sensor mount orientation varies by laptop model. Override via
# GC2607_ROTATION env in the systemd unit if your image is flipped:
#   none | hflip (default) | rot180
ROT="${GC2607_ROTATION:-hflip}"
log "Starting ISP (capture=$CAPTURE_DEV output=$LOOP_DEV rotation=$ROT)..."
if [ -x "${SCRIPT_DIR}/gc2607_isp" ]; then
    exec "${SCRIPT_DIR}/gc2607_isp" "$CAPTURE_DEV" "$LOOP_DEV" "$ROT"
else
    # Fallback to Python virtualcam
    log "gc2607_isp not found, falling back to Python virtualcam"
    if [ -f "${SCRIPT_DIR}/.python-path" ]; then
        PYTHON="$(cat "${SCRIPT_DIR}/.python-path")"
    else
        PYTHON="python3"
    fi
    exec "$PYTHON" "${SCRIPT_DIR}/gc2607_virtualcam.py" "$CAPTURE_DEV" "$LOOP_DEV"
fi
