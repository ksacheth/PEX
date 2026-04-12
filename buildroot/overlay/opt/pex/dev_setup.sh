#!/bin/sh
#
# dev_setup.sh -- Load pex.ko and create /dev/pex
# Simplified version for Buildroot rootfs
#

set -e

MODULE_PATH="/lib/modules/pex.ko"

if [ ! -f "${MODULE_PATH}" ]; then
    echo "ERROR: pex.ko not found at ${MODULE_PATH}" >&2
    exit 1
fi

# Unload if already loaded
if grep -q '^pex ' /proc/modules 2>/dev/null; then
    rmmod pex 2>/dev/null || true
fi

# Load the module
insmod "${MODULE_PATH}"
echo "PEX module loaded."

# Create device node
major=$(grep ' pex$' /proc/devices | awk '{print $1}')
if [ -z "${major}" ]; then
    echo "ERROR: Cannot find pex major number in /proc/devices" >&2
    exit 1
fi

rm -f /dev/pex
mknod /dev/pex c "${major}" 0
chmod 666 /dev/pex

echo "PEX device ready at /dev/pex (major=${major})."
