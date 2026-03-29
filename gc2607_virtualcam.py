#!/usr/bin/env python3
"""
Real-time virtual camera for GC2607 sensor.

Captures raw 10-bit GRBG Bayer from the sensor, applies proper demosaicing,
per-frame gray-world white balance, sRGB gamma, and auto-exposure.

Usage:
    sudo python3 gc2607_virtualcam.py [capture_dev] [output_dev]
"""

import sys
import subprocess
import time
import signal
import numpy as np
import pyfakewebcam

# Sensor parameters
WIDTH = 1920
HEIGHT = 1080
FRAME_SIZE = WIDTH * HEIGHT * 2  # 10-bit packed as uint16

# Hardware black level (noise floor) - found to be 64 via raw analysis
BLACK_LEVEL = 64

# Output is half resolution (2x2 demosaic)
OUT_W = WIDTH // 2   # 960
OUT_H = HEIGHT // 2  # 540

# WB smoothing (0-1, higher = more stable, less responsive)
WB_SMOOTHING = 0.85

# Auto-exposure target: median brightness in [0,255] output
# 128 = middle gray (standard 18% gray card target for AE)
AE_TARGET = 128
AE_SMOOTHING = 0.95  # slow adjustment to prevent flicker

# Sensor limits
EXPOSURE_MIN = 4
EXPOSURE_MAX = 2002
GAIN_MIN = 0
GAIN_MAX = 16

running = True


def signal_handler(sig, frame):
    global running
    running = False


def set_sensor_controls(subdev, exposure, gain):
    """Set sensor exposure and gain via v4l2-ctl."""
    exposure = int(np.clip(exposure, EXPOSURE_MIN, EXPOSURE_MAX))
    gain = int(np.clip(gain, GAIN_MIN, GAIN_MAX))
    subprocess.run(
        ['v4l2-ctl', '-d', subdev,
         '--set-ctrl', f'exposure={exposure},analogue_gain={gain}'],
        capture_output=True
    )
    return exposure, gain


def find_sensor_subdev():
    """Find the v4l-subdev with exposure control."""
    import glob
    for sd in sorted(glob.glob('/dev/v4l-subdev*')):
        result = subprocess.run(
            ['v4l2-ctl', '-d', sd, '--list-ctrls'],
            capture_output=True, text=True
        )
        if 'exposure' in result.stdout:
            return sd
    return None


def process_frame(raw_bytes, prev_gains, brightness):
    """Demosaic raw Bayer GRBG10 and apply gray-world white balance."""
    bayer = np.frombuffer(raw_bytes, dtype=np.uint16).reshape(HEIGHT, WIDTH)

    # Extract channels (GRBG pattern) - produces half-resolution output
    # Subtract hardware black level and clip to 0
    g1 = np.maximum(bayer[0::2, 0::2].astype(np.float32) - BLACK_LEVEL, 0)
    r  = np.maximum(bayer[0::2, 1::2].astype(np.float32) - BLACK_LEVEL, 0)
    b  = np.maximum(bayer[1::2, 0::2].astype(np.float32) - BLACK_LEVEL, 0)
    g2 = np.maximum(bayer[1::2, 1::2].astype(np.float32) - BLACK_LEVEL, 0)
    g  = (g1 + g2) * 0.5

    # Gray-world white balance (green as reference)
    r_avg = r.mean()
    g_avg = g.mean()
    b_avg = b.mean()

    # Use a small epsilon to avoid division by zero
    r_gain = g_avg / (r_avg + 1e-6)
    b_gain = g_avg / (b_avg + 1e-6)

    # Smooth gains across frames to prevent flicker
    if prev_gains is not None:
        r_gain = WB_SMOOTHING * prev_gains[0] + (1 - WB_SMOOTHING) * r_gain
        b_gain = WB_SMOOTHING * prev_gains[1] + (1 - WB_SMOOTHING) * b_gain

    r *= r_gain
    b *= b_gain

    # Normalize 10-bit to [0,1] with brightness
    # Since we subtracted 64, the new max is 1023 - 64 = 959
    scale = brightness / 959.0
    r = np.clip(r * scale, 0, 1)
    g = np.clip(g * scale, 0, 1)
    b = np.clip(b * scale, 0, 1)

    # sRGB gamma correction (linear → perceptual)
    r = np.power(r, 1.0 / 2.2)
    g = np.power(g, 1.0 / 2.2)
    b = np.power(b, 1.0 / 2.2)

    # Convert to 8-bit
    rgb = np.stack([r * 255, g * 255, b * 255], axis=2).astype(np.uint8)
    # Rotate 180°
    rgb = rgb[::-1, ::-1]

    # Measure median brightness for auto-exposure feedback
    luma = (0.299 * rgb[:,:,0].astype(np.float32) +
            0.587 * rgb[:,:,1].astype(np.float32) +
            0.114 * rgb[:,:,2].astype(np.float32))
    median_luma = np.median(luma)

    return rgb, (r_gain, b_gain), median_luma


def main():
    global running

    capture_dev = sys.argv[1] if len(sys.argv) > 1 else '/dev/video1'
    output_dev = sys.argv[2] if len(sys.argv) > 2 else '/dev/video50'

    print(f"GC2607 Virtual Camera")
    print(f"  Capture: {capture_dev} ({WIDTH}x{HEIGHT} BA10)")
    print(f"  Output:  {output_dev} ({OUT_W}x{OUT_H} RGB)")
    print(f"  Auto WB + Auto Exposure (target median={AE_TARGET})")
    print()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Find sensor subdev for exposure control
    subdev = find_sensor_subdev()
    if subdev:
        print(f"  Sensor subdev: {subdev}")
    else:
        print("  WARNING: No sensor subdev found, auto-exposure disabled")

    # Set initial exposure
    cur_exposure = 450
    cur_gain = 7
    if subdev:
        set_sensor_controls(subdev, cur_exposure, cur_gain)

    # Set up output via pyfakewebcam
    print("Setting up virtual camera...")
    cam = pyfakewebcam.FakeWebcam(output_dev, OUT_W, OUT_H)

    # Start v4l2-ctl streaming to stdout
    print("Starting capture...")
    proc = subprocess.Popen(
        ['v4l2-ctl', '-d', capture_dev,
         '--stream-mmap', '--stream-count=0',
         '--stream-to=-'],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL
    )

    print("Streaming... (Ctrl+C to stop)")
    prev_gains = None
    brightness = 1.0  # will be auto-adjusted
    frame_count = 0
    start_time = time.monotonic()
    last_report = start_time
    last_ae = start_time
    buf = b''

    try:
        while running and proc.poll() is None:
            # Read one frame
            while len(buf) < FRAME_SIZE:
                chunk = proc.stdout.read(FRAME_SIZE - len(buf))
                if not chunk:
                    running = False
                    break
                buf += chunk

            if not running or len(buf) < FRAME_SIZE:
                break

            frame_data = buf[:FRAME_SIZE]
            buf = buf[FRAME_SIZE:]

            rgb, prev_gains, median_luma = process_frame(frame_data, prev_gains, brightness)
            cam.schedule_frame(rgb)

            # Auto-exposure: adjust brightness multiplier to hit target
            # This is like a software AE loop — adjusts the digital gain
            # to keep median brightness at AE_TARGET (128 = middle gray)
            if median_luma > 0:
                ae_ratio = AE_TARGET / median_luma
                brightness = AE_SMOOTHING * brightness + (1 - AE_SMOOTHING) * (brightness * ae_ratio)
                brightness = np.clip(brightness, 0.3, 4.0)

            # Adjust sensor exposure every 2 seconds if brightness is railing
            now = time.monotonic()
            if subdev and now - last_ae >= 2.0:
                if brightness > 2.5 and cur_exposure < EXPOSURE_MAX:
                    # Software gain maxing out — need more sensor exposure
                    cur_exposure = min(int(cur_exposure * 1.3), EXPOSURE_MAX)
                    if cur_exposure == EXPOSURE_MAX and cur_gain < GAIN_MAX:
                        cur_gain = min(cur_gain + 1, GAIN_MAX)
                    set_sensor_controls(subdev, cur_exposure, cur_gain)
                    brightness = 1.0  # reset software gain
                elif brightness < 0.5 and cur_exposure > EXPOSURE_MIN:
                    # Too much light — reduce sensor exposure
                    cur_exposure = max(int(cur_exposure * 0.7), EXPOSURE_MIN)
                    if cur_exposure == EXPOSURE_MIN and cur_gain > GAIN_MIN:
                        cur_gain = max(cur_gain - 1, GAIN_MIN)
                    set_sensor_controls(subdev, cur_exposure, cur_gain)
                    brightness = 1.0
                last_ae = now

            frame_count += 1
            if now - last_report >= 5.0:
                fps = frame_count / (now - start_time)
                print(f"  {frame_count} frames, {fps:.1f} fps, "
                      f"WB: R={prev_gains[0]:.3f} B={prev_gains[1]:.3f}, "
                      f"AE: exp={cur_exposure} gain={cur_gain} bright={brightness:.2f} "
                      f"median={median_luma:.0f}")
                last_report = now

    finally:
        proc.terminate()
        proc.wait()
        elapsed = time.monotonic() - start_time
        if elapsed > 0 and frame_count > 0:
            print(f"\n{frame_count} frames in {elapsed:.1f}s = {frame_count/elapsed:.1f} fps")


if __name__ == '__main__':
    main()
