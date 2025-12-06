# TODO - zig-ublk Development Roadmap

## Phase 0: Zig Bootcamp

**Goal:** Learn the Zig APIs we'll need before writing any ublk code.

**See `docs/zig.md` and `docs/zig_api.md` for detailed findings.**

### 0.1 `std.os.linux.IO_Uring`

**Status:** Partially researched

**Findings:**
- [x] SQE128/CQE32 flags exist: `linux.IORING_SETUP_SQE128`, `linux.IORING_SETUP_CQE32`
- [x] URING_CMD opcode exists: `linux.IORING_OP.URING_CMD`
- [ ] **PROBLEM:** stdlib `io_uring_sqe` is 64 bytes, we need 128
- [ ] **PROBLEM:** stdlib cqe is 16 bytes, we need 32
- [ ] Need to test: Can IoUring.init_params handle SQE128 flag?
- [ ] Need to define: Custom 128-byte SQE struct

**Next experiment:** Create a simple test that tries SQE128 mode

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

## Phase 1: Core Infrastructure

- [x] Project skeleton (build.zig, src/root.zig)
- [x] Basic UAPI struct definitions (CtrlCmd, IoCmd, IoDesc, DevInfo)
- [x] Comptime struct size assertions
- [ ] Test SQE128/CQE32 io_uring creation
- [ ] Define 128-byte SQE struct
- [ ] Open /dev/ublk-control

## Phase 2: Device Lifecycle

- [ ] ADD_DEV command
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
