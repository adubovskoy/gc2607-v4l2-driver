#!/bin/bash
# Downloads the matching ipu-bridge.c from kernel.org and patches it.
# Called by DKMS before make. $kernelver is set by DKMS.
set -euo pipefail

if [ -z "${kernelver:-}" ]; then
    echo "ERROR: kernelver not set" >&2
    exit 1
fi

# Extract upstream version: "6.19.13-arch1-1" -> "6.19.13"
kver_short="${kernelver%%-*}"

echo "Downloading ipu-bridge.c for kernel ${kver_short}..."

# Try git.kernel.org first (single file, fast), fall back to tarball
if curl -sfL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/media/pci/intel/ipu-bridge.c?h=v${kver_short}" -o ipu-bridge.c 2>/dev/null && [ -s ipu-bridge.c ]; then
    echo "Downloaded from git.kernel.org"
else
    echo "Trying kernel tarball..."
    major="${kver_short%%.*}"
    curl -sL "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${kver_short}.tar.xz" \
        | xz -d \
        | tar -xf - "linux-${kver_short}/drivers/media/pci/intel/ipu-bridge.c" \
            --strip-components=4 -C .
fi

if [ ! -s ipu-bridge.c ]; then
    echo "ERROR: failed to get ipu-bridge.c for kernel ${kver_short}" >&2
    exit 1
fi

# Patch: add GCTI2607 sensor config (if not already present)
if ! grep -q "GCTI2607" ipu-bridge.c; then
    echo "Patching ipu-bridge.c to add GCTI2607..."
    sed -i '/static const struct ipu_sensor_config ipu_supported_sensors\[\] = {/a\\t/* GalaxyCore GC2607 */\n\tIPU_SENSOR_CONFIG("GCTI2607", 1, 336000000),' ipu-bridge.c

    if ! grep -q "GCTI2607" ipu-bridge.c; then
        echo "ERROR: patch failed" >&2
        exit 1
    fi
else
    echo "GCTI2607 already present in upstream source"
fi

echo "ipu-bridge.c ready."
