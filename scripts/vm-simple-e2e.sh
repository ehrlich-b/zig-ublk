#!/bin/bash
# Simple e2e test for zig-ublk
# This runs on the VM, not locally

set -euo pipefail

echo "=== ZIG-UBLK SIMPLE E2E TEST ==="
echo ""

# Check ublk module
echo "Checking ublk_drv module..."
if ! lsmod | grep -q ublk_drv; then
    echo "Loading ublk_drv..."
    sudo modprobe ublk_drv || {
        echo "ERROR: Failed to load ublk_drv"
        exit 1
    }
fi
echo "✓ ublk_drv loaded"

# Check control device
if [ ! -e /dev/ublk-control ]; then
    echo "ERROR: /dev/ublk-control not found"
    exit 1
fi
echo "✓ /dev/ublk-control exists"

echo ""
echo "=== RUNNING EXAMPLE-NULL ==="
echo ""

# Run the binary (requires sudo for io_uring setup)
sudo ./example-null

echo ""
echo "=== TEST COMPLETE ==="
