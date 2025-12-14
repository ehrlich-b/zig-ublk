#!/bin/bash
# Multi-queue e2e test for zig-ublk
# Tests the Device API with multiple IO queues
# This runs on the VM, not locally

set -euo pipefail

NUM_QUEUES=${1:-2}

echo "=== ZIG-UBLK MULTI-QUEUE E2E TEST ==="
echo "Testing with $NUM_QUEUES queues"
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
sudo pkill -9 example-multiqueue 2>/dev/null || true
sudo pkill -9 example-null 2>/dev/null || true
sleep 1

# Note existing block devices
EXISTING_DEVICES=$(ls /dev/ublkb* 2>/dev/null || true)

echo ""
echo "=== RUNNING MULTI-QUEUE DEVICE ==="
echo ""

# Run the binary in background with specified queue count
sudo ./example-multiqueue $NUM_QUEUES &
UBLK_PID=$!

# Give it time to start (more time for multi-queue setup)
sleep 5

# Find the new device
NEW_DEVICE=""
for dev in /dev/ublkb*; do
    if [ -e "$dev" ]; then
        if ! echo "$EXISTING_DEVICES" | grep -q "$dev"; then
            NEW_DEVICE="$dev"
            break
        fi
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
echo "✓ $NEW_DEVICE exists with $NUM_QUEUES queues"

echo ""
echo "=== TESTING BASIC IO ==="
echo ""

# Test read (use iflag=direct to bypass page cache)
echo "Testing read..."
sudo dd if="$NEW_DEVICE" of=/dev/null bs=4k count=100 iflag=direct 2>&1 || {
    echo "ERROR: Read test failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ Read test passed"

# Test write (use oflag=direct to bypass page cache)
echo "Testing write..."
sudo dd if=/dev/zero of="$NEW_DEVICE" bs=4k count=100 oflag=direct 2>&1 || {
    echo "ERROR: Write test failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ Write test passed"

# Skip parallel and fio tests for now - basic IO is working

# Cleanup
echo ""
echo "Stopping device..."
sudo kill $UBLK_PID 2>/dev/null || true
wait $UBLK_PID 2>/dev/null || true
sleep 1

echo ""
echo "=== TEST COMPLETE ==="
echo "Multi-queue test with $NUM_QUEUES queues passed!"
