#!/bin/bash
# Create depmod override so our patched ipu-bridge in the DKMS updates/
# tree takes priority over the stock in-tree module in kernel/
DEPMOD_CONF="/etc/depmod.d/ipu-bridge-gc2607.conf"
if [ ! -f "$DEPMOD_CONF" ]; then
    echo "override ipu_bridge * extra" > "$DEPMOD_CONF"
    echo "Created depmod override: $DEPMOD_CONF"
fi
