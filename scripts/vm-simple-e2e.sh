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

# Clean up any existing ublk device
sudo pkill -9 example-null 2>/dev/null || true
sleep 1

# Note existing block devices
EXISTING_DEVICES=$(ls /dev/ublkb* 2>/dev/null || true)

echo ""
echo "=== RUNNING NULL DEVICE ==="
echo ""

# Run the binary in background
sudo ./example-null &
UBLK_PID=$!

# Give it time to start
sleep 3

# Find the new device (may be ublkb0, ublkb1, etc)
NEW_DEVICE=""
for dev in /dev/ublkb*; do
    if [ -e "$dev" ]; then
        # Check if this is a new device
        if ! echo "$EXISTING_DEVICES" | grep -q "$dev"; then
            NEW_DEVICE="$dev"
            break
        fi
        # Or if no existing devices, use the first one
        if [ -z "$EXISTING_DEVICES" ]; then
            NEW_DEVICE="$dev"
            break
        fi
    fi
done

if [ -z "$NEW_DEVICE" ]; then
    echo "ERROR: No ublk block device appeared"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
fi
echo "✓ $NEW_DEVICE exists"

echo ""
echo "=== TESTING IO ==="
echo ""

# Test read
echo "Testing read..."
sudo dd if="$NEW_DEVICE" of=/dev/null bs=4k count=10 2>&1 || {
    echo "ERROR: Read test failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ Read test passed"

# Test write
echo "Testing write..."
sudo dd if=/dev/zero of="$NEW_DEVICE" bs=4k count=10 2>&1 || {
    echo "ERROR: Write test failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ Write test passed"

# Verify read returns zeros
echo "Verifying read returns zeros..."
DATA=$(sudo dd if="$NEW_DEVICE" bs=512 count=1 2>/dev/null | xxd -p | head -c 32)
if [ "$DATA" = "00000000000000000000000000000000" ]; then
    echo "✓ Read returns zeros"
else
    echo "ERROR: Read did not return zeros: $DATA"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
fi

# Cleanup
echo ""
echo "Stopping device..."
sudo kill $UBLK_PID 2>/dev/null || true
wait $UBLK_PID 2>/dev/null || true
sleep 1

echo ""
echo "=== TEST COMPLETE ==="
echo "All tests passed!"
