# Makefile for zig-ublk

# Include local overrides if present (gitignored)
-include Makefile.local

#==============================================================================
# Zig Build Configuration
#==============================================================================

.PHONY: build test run clean version

build:
	zig build

# Build for VM (baseline x86_64, no fancy CPU features)
build-vm:
	zig build -Dcpu=baseline -Doptimize=ReleaseFast

test:
	zig build test

run:
	zig build run-example-null

clean:
	rm -rf zig-out .zig-cache zig-cache

version:
	zig version

#==============================================================================
# VM Configuration (override in Makefile.local or environment)
#==============================================================================

VM_HOST ?= $(UBLK_VM_HOST)
VM_USER ?= $(UBLK_VM_USER)
VM_DIR  ?= ~/ublk-test
VM_PASS ?= $(UBLK_VM_PASS)

# SSH command construction
ifdef VM_PASS
  VM_SSH = sshpass -p "$(VM_PASS)" ssh -o StrictHostKeyChecking=no $(VM_USER)@$(VM_HOST)
  VM_SCP = sshpass -p "$(VM_PASS)" scp -o StrictHostKeyChecking=no
else
  VM_SSH = ssh $(VM_USER)@$(VM_HOST)
  VM_SCP = scp
endif

#==============================================================================
# VM Testing (requires VM_HOST, VM_USER configured)
#==============================================================================

.PHONY: vm-check vm-copy vm-simple-e2e vm-multiqueue-e2e vm-multiqueue-bench vm-reset vm-trace

# Check VM configuration
vm-check:
	@if [ -z "$(VM_HOST)" ] || [ -z "$(VM_USER)" ]; then \
		echo "Error: VM not configured"; \
		echo "Set VM_HOST and VM_USER in Makefile.local or environment:"; \
		echo "  export UBLK_VM_HOST=192.168.1.100"; \
		echo "  export UBLK_VM_USER=myuser"; \
		echo "  export UBLK_VM_PASS=mypassword  # or use SSH keys"; \
		echo ""; \
		echo "Or copy Makefile.local.example to Makefile.local and edit it."; \
		exit 1; \
	fi
	@echo "VM configured: $(VM_USER)@$(VM_HOST)"

# Copy binary to VM
vm-copy: vm-check build-vm
	@echo "Copying zig-ublk binaries to VM..."
	@$(VM_SSH) "mkdir -p $(VM_DIR); sudo killall example-null example-memory example-null-bench example-multiqueue 2>/dev/null || true"
	@$(VM_SCP) zig-out/bin/example-null zig-out/bin/example-memory zig-out/bin/example-null-bench zig-out/bin/example-multiqueue $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@echo "Copied."

# Run simple e2e test on VM (null backend)
vm-simple-e2e: vm-copy
	@echo "Running simple I/O test (null backend)..."
	@$(VM_SCP) scripts/vm-simple-e2e.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 60 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-simple-e2e.sh && ./vm-simple-e2e.sh" || \
		(echo "Test timed out" && $(MAKE) vm-trace && exit 1)

# Run memory backend e2e test on VM
vm-memory-e2e: vm-copy
	@echo "Running memory backend I/O test (RAM disk)..."
	@$(VM_SCP) scripts/vm-memory-e2e.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 60 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-memory-e2e.sh && ./vm-memory-e2e.sh" || \
		(echo "Test timed out" && $(MAKE) vm-trace && exit 1)

# Run IOPS benchmark
vm-benchmark: vm-copy
	@echo "Running IOPS benchmark..."
	@$(VM_SCP) scripts/vm-benchmark.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 120 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-benchmark.sh && ./vm-benchmark.sh" || \
		(echo "Benchmark timed out" && exit 1)

# Run multi-queue e2e test
vm-multiqueue-e2e: vm-copy
	@echo "Running multi-queue I/O test..."
	@$(VM_SCP) scripts/vm-multiqueue-e2e.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 120 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-multiqueue-e2e.sh && ./vm-multiqueue-e2e.sh 4" || \
		(echo "Test timed out" && $(MAKE) vm-trace && exit 1)

# Run multi-queue scaling benchmark
vm-multiqueue-bench: vm-copy
	@echo "Running multi-queue scaling benchmark..."
	@$(VM_SCP) scripts/vm-multiqueue-bench.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 300 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-multiqueue-bench.sh && ./vm-multiqueue-bench.sh" || \
		(echo "Benchmark timed out" && exit 1)

# Run comprehensive fuzz test
vm-fuzz: vm-copy
	@echo "Running comprehensive fuzz test..."
	@$(VM_SCP) scripts/vm-fuzz.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 900 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-fuzz.sh && ./vm-fuzz.sh" || \
		(echo "Fuzz test timed out" && exit 1)

# Run stress test (multiple cycles)
vm-stress: vm-copy
	@echo "Running stress test (5 cycles)..."
	@$(VM_SCP) scripts/vm-stress.sh scripts/vm-memory-e2e.sh scripts/vm-benchmark.sh $(VM_USER)@$(VM_HOST):$(VM_DIR)/
	@timeout 900 $(VM_SSH) "cd $(VM_DIR) && chmod +x ./vm-stress.sh ./vm-memory-e2e.sh ./vm-benchmark.sh && ./vm-stress.sh 5" || \
		(echo "Stress test timed out" && exit 1)

# Run the full gauntlet (e2e + fuzz + stress + multiqueue)
vm-gauntlet: vm-copy
	@echo "=== RUNNING THE GAUNTLET ==="
	@echo ""
	@echo "[1/5] Simple E2E test..."
	@$(MAKE) vm-simple-e2e
	@echo ""
	@echo "[2/5] Memory E2E test..."
	@$(MAKE) vm-memory-e2e
	@echo ""
	@echo "[3/5] Multi-queue E2E test..."
	@$(MAKE) vm-multiqueue-e2e
	@echo ""
	@echo "[4/5] Fuzz test..."
	@$(MAKE) vm-fuzz
	@echo ""
	@echo "[5/5] Stress test..."
	@$(MAKE) vm-stress
	@echo ""
	@echo "=== GAUNTLET COMPLETE ==="

# Debug - run ad-hoc commands on VM (edit command as needed)
vm-debug: vm-copy
	@echo "Running multiqueue debug test..."
	@$(VM_SSH) "cd $(VM_DIR) && sudo pkill example-multiqueue 2>/dev/null || true; sleep 1; sudo modprobe -r ublk_drv 2>/dev/null || true; sleep 1; sudo modprobe ublk_drv; sleep 1"
	@timeout 90 $(VM_SSH) "cd $(VM_DIR) && sudo ./example-multiqueue 2 2>&1 & sleep 8 && ls -la /dev/ublkb* 2>&1 && echo 'Read:' && timeout 10 sudo dd if=/dev/ublkb0 of=/dev/null bs=4k count=10 iflag=direct 2>&1 && echo 'Write:' && timeout 10 sudo dd if=/dev/zero of=/dev/ublkb0 bs=4k count=10 oflag=direct 2>&1 && echo 'All OK'; sudo pkill -f example-multiqueue 2>/dev/null; exit 0"

# Hard reset VM
vm-reset: vm-check
	@echo "Hard reset VM..."
	@timeout 3 $(VM_SSH) 'sudo sh -c "echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger"' || true
	@echo "Waiting for VM..."
	@for i in $$(seq 1 30); do \
		sleep 2; \
		if $(VM_SSH) 'echo ok' >/dev/null 2>&1; then echo "VM up"; break; fi; \
		echo "  ($$i/30)..."; \
	done
	@sleep 5
	@$(VM_SSH) 'sudo pkill -9 example-null 2>/dev/null || true; sudo modprobe -r ublk_drv 2>/dev/null || true; sudo modprobe ublk_drv'
	@echo "VM reset complete"

# Dump kernel trace from VM
vm-trace: vm-check
	@$(VM_SSH) 'sudo cat /sys/kernel/tracing/trace 2>/dev/null | tail -50 || echo "No trace available"'

# Check ublk kernel support on VM
vm-kernel-check: vm-check
	@$(VM_SSH) "uname -r && lsmod | grep ublk || echo 'ublk_drv not loaded'"

#==============================================================================
# Help
#==============================================================================

.PHONY: help

help:
	@echo "zig-ublk Makefile"
	@echo ""
	@echo "Build targets:"
	@echo "  build          Build the project"
	@echo "  test           Run unit tests"
	@echo "  clean          Remove build artifacts"
	@echo ""
	@echo "VM targets (require Makefile.local):"
	@echo "  vm-check            Verify VM configuration"
	@echo "  vm-copy             Copy binaries to VM"
	@echo "  vm-simple-e2e       Run null backend I/O test on VM"
	@echo "  vm-memory-e2e       Run memory backend I/O test on VM"
	@echo "  vm-multiqueue-e2e   Run multi-queue I/O test on VM"
	@echo "  vm-benchmark        Run IOPS benchmark (single queue)"
	@echo "  vm-multiqueue-bench Run multi-queue scaling benchmark"
	@echo "  vm-fuzz             Run comprehensive fuzz test"
	@echo "  vm-stress           Run stress test (5 cycles)"
	@echo "  vm-gauntlet         Run ALL tests"
	@echo "  vm-reset            Hard reset VM"
	@echo ""
	@echo "See docs/VM_TESTING.md for VM setup instructions."
