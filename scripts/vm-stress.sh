#!/bin/bash
# Stress test - alternates between e2e tests and benchmarks
# Tests stability under repeated cycles

set -e

CYCLES=${1:-5}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=============================================="
echo "       zig-ublk Stress Test"
echo "=============================================="
echo "Cycles: $CYCLES"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

for i in $(seq 1 $CYCLES); do
    echo ""
    echo -e "${YELLOW}=== CYCLE $i / $CYCLES ===${NC}"
    echo ""

    # Run memory e2e test
    echo "--- Memory E2E Test ---"
    if ./vm-memory-e2e.sh; then
        echo -e "${GREEN}E2E PASS${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}E2E FAIL${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    sleep 2

    # Run quick benchmark
    echo ""
    echo "--- Quick Benchmark ---"
    if ./vm-benchmark.sh; then
        echo -e "${GREEN}BENCHMARK PASS${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}BENCHMARK FAIL${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    sleep 2
done

echo ""
echo "=============================================="
echo "            STRESS TEST SUMMARY"
echo "=============================================="
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Tests passed: $PASS_COUNT / $TOTAL"
echo "Cycles completed: $CYCLES"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}STRESS TEST FAILED${NC}: $FAIL_COUNT test(s) failed"
    exit 1
else
    echo -e "${GREEN}ALL STRESS TESTS PASSED${NC}"
    exit 0
fi
