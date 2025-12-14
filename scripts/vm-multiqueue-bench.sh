#!/bin/bash
# Multi-queue IOPS scaling benchmark for zig-ublk
# Tests IOPS with 1, 2, 4, and 8 queues
# This runs on the VM, not locally

set -euo pipefail

echo "=== ZIG-UBLK MULTI-QUEUE SCALING BENCHMARK ==="
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
    sudo pkill -9 example-multiqueue 2>/dev/null || true
    sudo pkill -9 example-null-bench 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# FIO parameters - 4K random read, matching jobs to queue count
FIO_BASE="--rw=randread --bs=4k --direct=1 --ioengine=libaio --iodepth=64 --runtime=10 --time_based --group_reporting"

run_benchmark() {
    local num_queues=$1
    local binary=$2
    local args=${3:-}

    echo ""
    echo "=== Benchmarking: $num_queues queue(s) ==="

    cleanup

    # Start the backend
    if [ -n "$args" ]; then
        sudo ./$binary $args &
    else
        sudo ./$binary &
    fi
    local pid=$!
    sleep 5

    # Find the device
    local device=""
    for dev in /dev/ublkb*; do
        if [ -e "$dev" ]; then
            device="$dev"
            break
        fi
    done

    if [ -z "$device" ]; then
        echo "ERROR: No ublk device found"
        return 1
    fi

    echo "Device: $device"
    echo "Running fio with $num_queues job(s)..."

    # Run fio with numjobs matching queue count
    local result=$(sudo fio --name=bench $FIO_BASE --filename="$device" --numjobs=$num_queues 2>&1)

    # Extract IOPS
    local iops=$(echo "$result" | grep -oP 'IOPS=\K[0-9.]+[kKmM]?' | head -1)
    if [ -z "$iops" ]; then
        iops=$(echo "$result" | grep -oP 'iops\s*:\s*avg=\K[0-9.]+' | head -1)
    fi

    echo "IOPS: $iops"

    # Store for summary
    RESULTS+=("$num_queues queues: $iops IOPS")

    # Cleanup
    sudo kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    sleep 2
}

# Array to store results
declare -a RESULTS=()

echo ""
echo "This benchmark measures IOPS scaling with queue count."
echo "Expected: Near-linear scaling (2x queues ≈ 2x IOPS)"
echo ""

# Single queue baseline (use example-null-bench for comparison)
if [ -f "./example-null-bench" ]; then
    echo "=== BASELINE: Single-queue (example-null-bench) ==="
    run_benchmark 1 "example-null-bench"
fi

# Multi-queue tests
if [ -f "./example-multiqueue" ]; then
    # Test with 1, 2, 4 queues
    for nq in 1 2 4; do
        run_benchmark $nq "example-multiqueue" "$nq"
    done

    # Test with 8 queues if system has enough CPUs
    cpu_count=$(nproc)
    if [ $cpu_count -ge 8 ]; then
        run_benchmark 8 "example-multiqueue" "8"
    else
        echo ""
        echo "Skipping 8-queue test (only $cpu_count CPUs available)"
    fi
else
    echo "ERROR: example-multiqueue not found"
    exit 1
fi

echo ""
echo "=========================================="
echo "           SCALING SUMMARY"
echo "=========================================="
for result in "${RESULTS[@]}"; do
    echo "  $result"
done
echo "=========================================="
echo ""

# Calculate scaling efficiency if we have baseline
if [ ${#RESULTS[@]} -ge 2 ]; then
    echo "Note: Ideal scaling is linear (2x queues = 2x IOPS)"
    echo "Actual scaling depends on CPU cores and backend overhead."
fi

echo ""
echo "=== BENCHMARK COMPLETE ==="
