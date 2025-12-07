# TODO - zig-ublk Development Roadmap

## Phase 0: Zig Bootcamp

**Goal:** Learn the Zig APIs we'll need before writing any ublk code.

**See `docs/zig.md` and `docs/zig_api.md` for detailed findings.**

### 0.1 `std.os.linux.IO_Uring`

**Status:** SOLVED

**Findings:**
- [x] SQE128/CQE32 flags exist: `linux.IORING_SETUP_SQE128`, `linux.IORING_SETUP_CQE32`
- [x] URING_CMD opcode exists: `linux.IORING_OP.URING_CMD` (opcode 46, not 27!)
- [x] **PROBLEM:** stdlib `io_uring_sqe` is 64 bytes - SOLVED with custom IoUringSqe128
- [x] **PROBLEM:** stdlib cqe is 16 bytes - SOLVED with custom IoUringCqe32
- [x] stdlib IoUring.init_params does NOT work for SQE128 (wrong mmap size)
- [x] Implemented: `IoUring128` - raw io_uring wrapper for SQE128/CQE32
- [x] **Confirmed:** stdlib limitation is a known gap - PR #13986 attempted fix but was abandoned

**Solution:** Created `IoUring128` in src/ring.zig that:
- Uses raw `io_uring_setup` syscall with correct flags
- mmaps SQEs at 128 bytes per entry
- mmaps CQEs at 32 bytes per entry
- Provides `getSqe()`, `submit()`, `copyCqes()` methods

### 0.2 `std.os.linux` - Syscalls

**Status:** DONE

- [x] Test posix.open with device files - used in Controller.init(), Queue.init()
- [x] Test linux.mmap patterns - used in Queue.init() for descriptors and buffers
- [x] Document error handling patterns - see docs/idioms.md

### 0.3 Build System

**Status:** DONE

- [x] build.zig works with 0.16 API
- [x] Module-based architecture (addModule, createModule)
- [x] Tests run via `zig build test`
- See `docs/zig.md` for build API details

### 0.4 Packed Structs and Kernel ABI

**Status:** DONE

**Findings:**
- [x] Use `extern struct` for kernel ABI (C layout)
- [x] Comptime size checks work: `comptime { std.debug.assert(@sizeOf(T) == N); }`
- [x] All struct definitions have size assertions (UblksrvCtrlCmd=32, IoCmd=16, IoDesc=24, DevInfo=64)
- [x] Alignment verified via VM testing - kernel accepts all our structures

### 0.5 Error Handling

**Status:** DONE

- [x] Error sets used throughout (InitError, ControlError, QueueError)
- [x] `try`/`catch` patterns documented in docs/idioms.md
- [x] `errdefer` for resource cleanup (e.g., ring.deinit on init failure)

### 0.6 Memory Management

**Status:** DONE

- [x] Allocator pattern used correctly (Queue.init takes allocator, stores it, uses in deinit)
- [x] mmap/munmap for kernel memory regions
- [x] No memory leaks verified via GPA in examples

### 0.7 Interfaces and Callbacks

**Status:** DONE

- [x] IoHandler function pointer type defined in queue.zig
- [x] Callbacks used for IO handling: `*const fn (*Queue, u16, UblksrvIoDesc, []u8) i32`

---

## Phase 1: Core Infrastructure - COMPLETE ✓

- [x] Project skeleton (build.zig, src/root.zig)
- [x] Basic UAPI struct definitions (CtrlCmd, IoCmd, IoDesc, DevInfo)
- [x] Comptime struct size assertions
- [x] Test SQE128/CQE32 io_uring creation (IoUring128)
- [x] Define 128-byte SQE struct (IoUringSqe128)
- [x] Open /dev/ublk-control (Controller.init() - **VM TESTED**)
- [x] Send ADD_DEV command - **VM TESTED** - creates /dev/ublkcN

## Phase 2: Device Lifecycle - COMPLETE ✓ - **VM TESTED**

- [x] ADD_DEV command (creates device, assigns ID) - **VM TESTED**
- [x] SET_PARAMS command (configure device parameters) - **VM TESTED**
- [x] GET_DEV_INFO command - **VM TESTED**
- [x] START_DEV command (requires IO queues first)
- [x] STOP_DEV command
- [x] DEL_DEV command - **VM TESTED**

**Note:** START_DEV can only be called after IO queues submit FETCH_REQ (Phase 3)

## Phase 3: IO Path - COMPLETE ✓ - **VM TESTED**

- [x] Queue setup (open /dev/ublkcN, mmap descriptors) - **VM TESTED**
- [x] FETCH_REQ submission - **VM TESTED**
- [x] Completion handling - **VM TESTED**
- [x] COMMIT_AND_FETCH_REQ - **VM TESTED**
- [x] IO buffer management - **VM TESTED**
- [x] Tag state machine (in_flight_fetch → owned → in_flight_commit)

**Key insight:** Kernel requires queue thread to be in io_uring wait state (io_uring_enter with GETEVENTS) BEFORE START_DEV can complete. Queue must run in separate thread.

## Phase 4: Backends

- [x] Null backend (simplest - for testing) - **VM TESTED** in examples/null.zig
- [x] Memory backend (RAM disk) - **VM TESTED** in examples/memory.zig

## Phase 4.5: Code Review - COMPLETE ✓

- [x] Split root.zig into modules:
  - `uapi.zig` - kernel ABI structs, constants, ioctl encoding, IoOp enum
  - `params.zig` - UblkParams and related parameter structs
  - `ring.zig` - IoUring128, IoUringSqe128, IoUringCqe32
  - `control.zig` - Controller struct
  - `queue.zig` - Queue struct
  - `root.zig` - thin re-export layer (~100 lines)
- [x] Add constants for IO operation codes (IoOp enum in uapi.zig)
- [x] VM tested - all e2e tests pass

## Phase 5: Polish

- [x] Benchmarks vs go-ublk - **118K IOPS** (zig-ublk) vs ~100K IOPS (go-ublk documented)
- [x] Examples with documentation - README.md updated, examples/README.md added
- [x] Test suite:
  - 22 unit tests (ioctl encoding, ring module, uapi enums, params)
  - VM integration tests: vm-simple-e2e, vm-memory-e2e, vm-benchmark
  - vm-fuzz: 20 comprehensive tests (data integrity, boundaries, concurrent I/O)
  - vm-stress: stability testing (repeated cycles)
- [x] API documentation - `zig build docs` generates HTML docs in zig-out/docs/

### Benchmark Results (2025-12-06)

```
zig-ublk null backend (ReleaseFast, no debug prints):
  IOPS: 118K avg (96K-134K range)
  BW: 460 MiB/s
  fio: randread, bs=4k, iodepth=64, libaio

go-ublk documented: ~100K IOPS
```

Key optimizations:
1. No debug prints in hot path (syscall overhead)
2. ReleaseFast build (-Doptimize=ReleaseFast)
3. Higher queue depth (128 vs 64)

---

## Phase 6: Multi-Queue Support

**Design Doc:** [docs/MULTI_QUEUE_DESIGN.md](docs/MULTI_QUEUE_DESIGN.md)

**Goal:** Feature parity with go-ublk - support multiple IO queues for parallel processing across CPU cores.

### 6.1 Core Infrastructure
- [ ] Create `src/device.zig` - Device struct to manage multiple queues
- [ ] Implement multi-queue initialization (nr_hw_queues > 1)
- [ ] Implement synchronized startup (all queues prime before START_DEV)
- [ ] Implement clean shutdown (signal all threads, join, cleanup)

### 6.2 Thread-Safe Backends
- [ ] Add sharded RwLock to memory backend
- [ ] Update examples/memory.zig for thread safety
- [ ] Document thread-safety requirements for custom backends

### 6.3 CPU Affinity (Optional)
- [ ] Implement sched_setaffinity wrapper
- [ ] Add cpu_affinity config option to Device
- [ ] Document NUMA optimization considerations

### 6.4 Testing & Benchmarking
- [ ] Add vm-multiqueue-e2e.sh test script
- [ ] Add vm-multiqueue-bench.sh for scaling tests
- [ ] Measure IOPS scaling: 1, 2, 4, 8 queues
- [ ] Update benchmark results

### Expected Results
- Near-linear IOPS scaling with queue count (CPU-bound)
- 4 queues on 4-core system: ~400K+ IOPS (vs 118K single-queue)
