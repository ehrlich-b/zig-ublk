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

**Solution:** Created `IoUring128` in src/root.zig that:
- Uses raw `io_uring_setup` syscall with correct flags
- mmaps SQEs at 128 bytes per entry
- mmaps CQEs at 32 bytes per entry
- Provides `getSqe()`, `submit()`, `copyCqes()` methods

### 0.2 `std.os.linux` - Syscalls

**Status:** Need to explore

- [ ] Test posix.open with device files
- [ ] Test linux.mmap patterns
- [ ] Document error handling patterns

### 0.3 Build System

**Status:** DONE

- [x] build.zig works with 0.16 API
- [x] Module-based architecture (addModule, createModule)
- [x] Tests run via `zig build test`
- See `docs/zig.md` for build API details

### 0.4 Packed Structs and Kernel ABI

**Status:** Partially researched

**Findings:**
- [x] Use `extern struct` for kernel ABI (C layout)
- [x] Comptime size checks work: `comptime { std.debug.assert(@sizeOf(T) == N); }`
- [x] Current struct definitions in src/root.zig pass size tests
- [ ] Need to verify alignment matches kernel expectations

### 0.5 Error Handling

**Status:** Need to explore

### 0.6 Memory Management

**Status:** Need to explore

### 0.7 Interfaces and Callbacks

**Status:** Need to explore

---

## Phase 1: Core Infrastructure - COMPLETE ✓

- [x] Project skeleton (build.zig, src/root.zig)
- [x] Basic UAPI struct definitions (CtrlCmd, IoCmd, IoDesc, DevInfo)
- [x] Comptime struct size assertions
- [x] Test SQE128/CQE32 io_uring creation (IoUring128)
- [x] Define 128-byte SQE struct (IoUringSqe128)
- [x] Open /dev/ublk-control (Controller.init() - **VM TESTED**)
- [x] Send ADD_DEV command - **VM TESTED** - creates /dev/ublkcN

## Phase 2: Device Lifecycle

- [x] ADD_DEV command (creates device, assigns ID)
- [ ] SET_PARAMS command
- [ ] GET_DEV_INFO command
- [ ] START_DEV command
- [ ] STOP_DEV command
- [ ] DEL_DEV command

## Phase 3: IO Path

- [ ] Queue setup (open /dev/ublkcN, mmap descriptors)
- [ ] FETCH_REQ submission
- [ ] Completion handling
- [ ] COMMIT_AND_FETCH_REQ
- [ ] Backend interface definition
- [ ] IO buffer management

## Phase 4: Backends

- [ ] Null backend (simplest - for testing)
- [ ] Memory backend (RAM disk)
- [ ] Loop backend (file-backed)

## Phase 5: Polish

- [ ] Examples with documentation
- [ ] Test suite
- [ ] Benchmarks vs go-ublk
- [ ] API documentation
