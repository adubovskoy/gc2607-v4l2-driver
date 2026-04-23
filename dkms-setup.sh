#!/bin/bash
#
# Set up DKMS for gc2607 and patched ipu-bridge on Arch Linux / EndeavourOS.
# After this, both modules rebuild automatically on kernel updates.
#
# Usage: sudo ./dkms-setup.sh
#

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GC2607_VER="1.0"
BRIDGE_VER="1.0"
LINK_FREQ="336000000"

echo "=== Setting up DKMS for GC2607 camera (Arch Linux) ==="

# Install DKMS if needed
if ! command -v dkms &>/dev/null; then
    echo "Installing dkms..."
    pacman -S --needed --noconfirm dkms
fi

# Ensure kernel headers are installed for current kernel
if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    echo "Installing linux-headers..."
    pacman -S --needed --noconfirm linux-headers
fi

# Runtime tools required by the pre-build step
for cmd in curl tar xz; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Installing $cmd..."
        pacman -S --needed --noconfirm "$cmd"
    fi
done

# ── gc2607 DKMS package ────────────────────────────────────────────

echo ""
echo "[1/2] Setting up gc2607 DKMS package..."

GC2607_SRC="/usr/src/gc2607-${GC2607_VER}"

# Remove old version if exists
dkms remove "gc2607/${GC2607_VER}" --all 2>/dev/null || true
rm -rf "$GC2607_SRC"

mkdir -p "$GC2607_SRC"
cp "${SCRIPT_DIR}/gc2607.c" "$GC2607_SRC/"

cat > "$GC2607_SRC/Makefile" << 'EOF'
obj-m := gc2607.o
EOF

cat > "$GC2607_SRC/dkms.conf" << EOF
PACKAGE_NAME="gc2607"
PACKAGE_VERSION="${GC2607_VER}"

BUILT_MODULE_NAME[0]="gc2607"
BUILT_MODULE_LOCATION[0]="./"
DEST_MODULE_LOCATION[0]="/extra"

MAKE="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"

AUTOINSTALL="yes"
EOF

dkms add "gc2607/${GC2607_VER}"
dkms build "gc2607/${GC2607_VER}" -k "$(uname -r)"
dkms install --force "gc2607/${GC2607_VER}" -k "$(uname -r)"

echo "gc2607 DKMS package installed."

# ── ipu-bridge-gc2607 DKMS package ─────────────────────────────────

echo ""
echo "[2/2] Setting up ipu-bridge-gc2607 DKMS package..."

BRIDGE_SRC="/usr/src/ipu-bridge-gc2607-${BRIDGE_VER}"

# Remove old version if exists
dkms remove "ipu-bridge-gc2607/${BRIDGE_VER}" --all 2>/dev/null || true
rm -rf "$BRIDGE_SRC"

mkdir -p "$BRIDGE_SRC"

cat > "$BRIDGE_SRC/Makefile" << 'EOF'
obj-m := ipu-bridge.o
EOF

cat > "$BRIDGE_SRC/dkms.conf" << EOF
PACKAGE_NAME="ipu-bridge-gc2607"
PACKAGE_VERSION="${BRIDGE_VER}"

BUILT_MODULE_NAME[0]="ipu-bridge"
BUILT_MODULE_LOCATION[0]="./"
DEST_MODULE_LOCATION[0]="/extra"

MAKE="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"

PRE_BUILD="dkms-prebuild.sh"
POST_INSTALL="dkms-postinstall.sh"

AUTOINSTALL="yes"
EOF

cat > "$BRIDGE_SRC/dkms-prebuild.sh" << 'PREBUILD'
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
PREBUILD
chmod +x "$BRIDGE_SRC/dkms-prebuild.sh"

cat > "$BRIDGE_SRC/dkms-postinstall.sh" << 'POSTINSTALL'
#!/bin/bash
# Create depmod override so our patched ipu-bridge in the DKMS updates/
# tree takes priority over the stock in-tree module in kernel/
DEPMOD_CONF="/etc/depmod.d/ipu-bridge-gc2607.conf"
if [ ! -f "$DEPMOD_CONF" ]; then
    echo "override ipu_bridge * extra" > "$DEPMOD_CONF"
    echo "Created depmod override: $DEPMOD_CONF"
fi
POSTINSTALL
chmod +x "$BRIDGE_SRC/dkms-postinstall.sh"

dkms add "ipu-bridge-gc2607/${BRIDGE_VER}"
dkms build "ipu-bridge-gc2607/${BRIDGE_VER}" -k "$(uname -r)"
dkms install --force "ipu-bridge-gc2607/${BRIDGE_VER}" -k "$(uname -r)"

echo "ipu-bridge-gc2607 DKMS package installed."

# ── Verify ──────────────────────────────────────────────────────────

echo ""
echo "=== DKMS Status ==="
dkms status

echo ""
echo "=== Module locations ==="
modinfo -n gc2607 2>/dev/null || echo "gc2607: not found"
modinfo -n ipu_bridge 2>/dev/null || echo "ipu_bridge: not found"

echo ""
echo "=== Done ==="
echo "Both modules will now rebuild automatically on kernel updates."
echo ""
echo "To remove DKMS setup:"
echo "  sudo dkms uninstall gc2607/${GC2607_VER} --all"
echo "  sudo dkms remove gc2607/${GC2607_VER} --all"
echo "  sudo dkms uninstall ipu-bridge-gc2607/${BRIDGE_VER} --all"
echo "  sudo dkms remove ipu-bridge-gc2607/${BRIDGE_VER} --all"
echo "  sudo rm -f /etc/depmod.d/ipu-bridge-gc2607.conf"
