# Resume: GC2607 Camera ISP Rewrite

**Date:** 2026-04-02
**Status:** IMPLEMENTED AND RUNNING
**Camera service:** RUNNING (gc2607_isp at ~4.7% CPU)

---

## Research Findings

### Problem 1: Color Tinge (Root Cause Identified)

The persistent color tinge (green/red/gray shifts) is caused by **manual color offsets** the previous agent added to `gc2607_virtualcam.py`:

| Parameter | Current Value | Correct Value | Effect of Current |
|-----------|--------------|---------------|-------------------|
| `G_OFFSET` | 0.75 | 1.0 | Reduces green 25% → pushes toward magenta/red |
| `R_OFFSET` | 1.05 | 1.0 | Boosts red 5% on top of WB → red tinge |
| `B_OFFSET` | 1.05 | 1.0 | Boosts blue 5% on top of WB |
| Cross-talk | `r -= 0.05*g, b -= 0.05*g` | Remove | Darkens R,B relative to G → green shift in highlights |

**Why these offsets exist:** The previous agent was trying to fix a green tinge by reducing green and boosting R/B. But this fights with the gray-world WB algorithm which already balances channels. The offsets create scene-dependent color shifts because they interact differently with different WB gains.

**Proof:** `view_raw_wb.py` (the reference that produces correct colors) uses pure gray-world WB with NO offsets and NO cross-talk reduction. It works correctly.

**The fix:** Remove all offsets, use pure gray-world WB. The S-curve gamma LUT is applied identically to all channels so it preserves color neutrality.

### Problem 2: CPU Usage (43% is too high)

**Current bottlenecks in Python virtualcam:**
1. **v4l2-ctl subprocess for capture** — reading 4MB/frame through a pipe adds overhead
2. **NumPy float32 processing** — 15M float ops per frame, Python interpreter overhead
3. **Multiple array passes** — black level, WB, scale, clip, LUT are separate passes over 1.5M pixels
4. **np.ascontiguousarray for 180° flip** — full frame copy
5. **pyfakewebcam** — does RGB→YUYV conversion in Python

**Research results (CPU-only, no GPU):**

| Approach | Estimated CPU | Dev Effort | Notes |
|----------|-------------|------------|-------|
| Current Python/NumPy | ~43% | N/A | Baseline |
| Python + OpenCV | ~25-30% | Trivial | OpenCV's cvtColor does optimized demosaic+color convert |
| C program with single-pass LUT | ~5-10% | Medium | All per-pixel ops composed into 3 LUTs, single memory pass |
| C program with AVX2 SIMD | ~3-5% | High | Hand-tuned SIMD intrinsics |

### Key Insight: Single-Pass Per-Channel LUT

All per-pixel operations (black level subtract → WB gain → brightness → gamma) can be **composed into a single 1024-entry LUT per channel**, recomputed once per frame. Per-pixel work becomes: read uint16 from Bayer, look up uint8 in table. One memory read + one table lookup per pixel per channel.

```
// Pseudocode - computed once per frame:
for (i = 0; i < 1024; i++) {
    float v = (i - BLACK_LEVEL) * wb_gain * brightness / 959.0;
    v = clamp(v, 0, 1);
    v = v * v * (3 - 2 * v);  // S-curve
    v = pow(v, 1/2.2);        // gamma
    lut_r[i] = (uint8_t)(v * 255);  // with r_gain baked in
}
```

Then per pixel: `out[pixel] = lut_r[bayer[row][col]]` — that's it.

---

## Implementation Plan

### Phase 1: C ISP Program (`gc2607_isp.c`)

A standalone C program that replaces `gc2607_virtualcam.py`:

1. **V4L2 capture** — open capture device directly via V4L2 ioctls + MMAP (no subprocess)
2. **v4l2loopback output** — open `/dev/video50`, write YUYV directly (no pyfakewebcam)
3. **Per-frame WB calculation** — subsample every 8th pixel for channel means (gray-world)
4. **Per-frame LUT build** — 3x 1024-entry uint8 LUTs encoding all per-pixel transforms
5. **Single-pass demosaic+LUT** — iterate Bayer in 2x2 blocks, extract R/G/B, apply per-channel LUT, write RGB or YUYV directly
6. **180° flip** — iterate output in reverse order (zero-cost, just pointer arithmetic)
7. **Auto-exposure** — measure mean of subsampled green channel, adjust hardware exposure/gain via v4l2 ioctls every 1.5s

**Output format:** YUYV 960x540 to v4l2loopback (same as current)

**Dependencies:** None beyond standard Linux headers (linux/videodev2.h, math.h). No external libs needed.

**Build:** Separate Makefile target or simple gcc command.

### Phase 2: Integration

1. Update `gc2607-service.sh` to run `gc2607_isp` instead of Python virtualcam
2. Update `gc2607-setup-service.sh` (no longer needs Python path detection)
3. Test color output, tune BLACK_LEVEL with actual dark frame measurement
4. Verify CPU usage with `ps` / `top`

### Phase 3: Polish (if needed)

- Add AWB smoothing (exponential moving average on WB gains)
- Fine-tune AE response curve
- Add signal handling for clean shutdown

---

## Color Tinge: Definitive Fix

The C implementation will use **pure gray-world WB with no manual offsets**:

```c
// Per-frame: compute from subsampled channel means
float r_gain = g_mean / r_mean;
float b_gain = g_mean / b_mean;
// Green gain is always 1.0 (reference channel)
// NO offsets, NO cross-talk reduction
```

This is exactly what `view_raw_wb.py` does and it produces correct colors. The S-curve + gamma LUT applied equally to all channels preserves color neutrality.

If there's a consistent color bias from the sensor itself (manufacturing variation), the correct fix is a **Color Correction Matrix (CCM)** — a 3x3 matrix applied in linear space before gamma. But this should only be added if pure gray-world WB is insufficient, and would be calibrated against a known target (gray card).

---

## Files That Will Be Created/Modified

- **NEW:** `gc2607_isp.c` — C ISP program (~400-600 lines)
- **MODIFY:** `Makefile` — add userspace ISP build target
- **MODIFY:** `gc2607-service.sh` — use C ISP instead of Python
- **MODIFY:** `gc2607-setup-service.sh` — simplify (no Python path needed)
- **KEEP:** `gc2607_virtualcam.py` — keep as fallback/reference
- **KEEP:** `view_raw_wb.py` — reference for correct color output

---

## Quick Reference (Service Management)

```bash
# Start camera manually
sudo systemctl start gc2607-camera.service

# Stop camera
sudo systemctl stop gc2607-camera.service

# Check status
sudo systemctl status gc2607-camera.service

# Enable auto-start at boot
sudo systemctl enable gc2607-camera.service

# Check CPU usage
ps -eo pid,pcpu,comm | grep gc2607
```
