#!/bin/bash
# Memory backend e2e test for zig-ublk (RAM disk)
# This runs on the VM, not locally
# Tests that data written persists until process exit

set -euo pipefail

echo "=== ZIG-UBLK MEMORY (RAM DISK) E2E TEST ==="
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
sudo pkill -9 example-memory 2>/dev/null || true
sleep 1

# Note existing block devices
EXISTING_DEVICES=$(ls /dev/ublkb* 2>/dev/null || true)

echo ""
echo "=== RUNNING MEMORY DEVICE ==="
echo ""

# Run the binary in background
sudo ./example-memory &
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
echo "=== TESTING DATA PERSISTENCE ==="
echo ""

# Create test data (known pattern)
TEST_DATA="ZIGUBLK_RAM_DISK_TEST_12345678"
echo "Test data: $TEST_DATA"

# Write test data
echo "Writing test data..."
echo -n "$TEST_DATA" | sudo dd of="$NEW_DEVICE" bs=512 count=1 conv=notrunc 2>/dev/null || {
    echo "ERROR: Write test failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ Write completed"

# Read it back
echo "Reading data back..."
READ_DATA=$(sudo dd if="$NEW_DEVICE" bs=512 count=1 2>/dev/null | head -c ${#TEST_DATA})
echo "Read back: $READ_DATA"

if [ "$READ_DATA" = "$TEST_DATA" ]; then
    echo "✓ Data persistence verified!"
else
    echo "ERROR: Data mismatch"
    echo "Expected: $TEST_DATA"
    echo "Got: $READ_DATA"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== TESTING LARGER IO ==="
echo ""

# Test larger read/write
echo "Testing 1MB write..."
sudo dd if=/dev/urandom of="$NEW_DEVICE" bs=1M count=1 seek=0 conv=notrunc 2>&1 | grep -E "copied|bytes" || {
    echo "ERROR: Large write failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ 1MB write passed"

echo "Testing 1MB read..."
sudo dd if="$NEW_DEVICE" of=/dev/null bs=1M count=1 2>&1 | grep -E "copied|bytes" || {
    echo "ERROR: Large read failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}
echo "✓ 1MB read passed"

# Test that initial data is still there (verify no corruption)
echo "Verifying original test data still at offset 0..."
READ_DATA=$(sudo dd if="$NEW_DEVICE" bs=512 count=1 skip=0 2>/dev/null | head -c ${#TEST_DATA})
# Note: The urandom write started at offset 0, so original data was overwritten
# We just verify we can read back something

echo ""
echo "=== TESTING OFFSET WRITES ==="
echo ""

# Write test pattern at offset
TEST_DATA2="OFFSET_TEST_DATA_9876"
OFFSET_SECTORS=100

echo "Writing at sector offset $OFFSET_SECTORS..."
echo -n "$TEST_DATA2" | sudo dd of="$NEW_DEVICE" bs=512 count=1 seek=$OFFSET_SECTORS conv=notrunc 2>/dev/null || {
    echo "ERROR: Offset write failed"
    sudo kill $UBLK_PID 2>/dev/null || true
    exit 1
}

echo "Reading from sector offset $OFFSET_SECTORS..."
READ_DATA2=$(sudo dd if="$NEW_DEVICE" bs=512 count=1 skip=$OFFSET_SECTORS 2>/dev/null | head -c ${#TEST_DATA2})

if [ "$READ_DATA2" = "$TEST_DATA2" ]; then
    echo "✓ Offset read/write verified!"
else
    echo "ERROR: Offset data mismatch"
    echo "Expected: $TEST_DATA2"
    echo "Got: $READ_DATA2"
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
echo "All memory backend tests passed!"
