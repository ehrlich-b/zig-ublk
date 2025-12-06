#!/bin/bash
# IOPS benchmark for zig-ublk vs go-ublk
# Runs on VM with fio

set -euo pipefail

echo "=== UBLK IOPS BENCHMARK ==="
echo ""

# Check fio is installed
if ! command -v fio &> /dev/null; then
    echo "Installing fio..."
    sudo apt-get update && sudo apt-get install -y fio
fi

# Check ublk module
if ! lsmod | grep -q ublk_drv; then
    sudo modprobe ublk_drv
fi

# Cleanup function
cleanup() {
    sudo pkill -9 example-null 2>/dev/null || true
    sudo pkill -9 go-ublk-null 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# FIO parameters - 4K random read is the standard IOPS benchmark
FIO_PARAMS="--name=iops --rw=randread --bs=4k --direct=1 --ioengine=libaio --iodepth=64 --numjobs=1 --runtime=10 --time_based --group_reporting"

run_benchmark() {
    local name=$1
    local binary=$2

    echo ""
    echo "=== Benchmarking: $name ==="

    cleanup

    # Start the backend
    sudo ./$binary &
    local pid=$!
    sleep 3

    # Find the device
    local device=""
    for dev in /dev/ublkb*; do
        if [ -e "$dev" ]; then
            device="$dev"
            break
        fi
    done

    if [ -z "$device" ]; then
        echo "ERROR: No ublk device found for $name"
        return 1
    fi

    echo "Device: $device"
    echo "Running fio (10 seconds)..."
    echo ""

    # Run fio
    sudo fio $FIO_PARAMS --filename="$device" 2>&1 | grep -E "iops|IOPS|bw="

    # Cleanup
    sudo kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    sleep 1
}

# Run zig-ublk benchmark (use bench version if available)
if [ -f "./example-null-bench" ]; then
    run_benchmark "zig-ublk" "example-null-bench"
elif [ -f "./example-null" ]; then
    echo "NOTE: Using example-null (debug version). Build example-null-bench for better performance."
    run_benchmark "zig-ublk" "example-null"
else
    echo "WARNING: No zig-ublk binary found, skipping benchmark"
fi

# Run go-ublk benchmark if available
if [ -f "./go-ublk-null" ]; then
    run_benchmark "go-ublk" "go-ublk-null"
else
    echo ""
    echo "NOTE: go-ublk-null not found. To compare:"
    echo "  1. Build go-ublk: cd .go-ublk-ref && go build -o go-ublk-null ./cmd/null"
    echo "  2. Copy to VM: scp go-ublk-null user@vm:~/ublk-test/"
fi

echo ""
echo "=== BENCHMARK COMPLETE ==="
