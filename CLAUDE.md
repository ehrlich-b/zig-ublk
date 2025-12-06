# CLAUDE.md - Project Guidance for zig-ublk

## Project Overview

zig-ublk is a native Zig implementation of Linux ublk (userspace block device driver).

**This is a learning-first project.** We're using go-ublk (`.go-ublk-ref/`) as a working reference for the ublk protocol and kernel interface - it tells us WHAT needs to happen. But HOW we implement it should be idiomatic Zig, not a line-by-line port.

The Go code is not sacred - it's just proof the protocol works. Our goal is clean, idiomatic Zig that a Zig developer would write.

## Anchor Documents

- `README.md` - Project overview and usage
- `TODO.md` - Development roadmap (Phase 0: Zig Bootcamp is critical!)
- `CLAUDE.md` - This file

## Zig Learning Docs (THE BIBLE)

**CRITICAL:** We're learning Zig as we go. These docs are our accumulated knowledge - cross-reference them BEFORE writing code:

- `docs/zig.md` - Zig 0.16 language features, build system, patterns
- `docs/zig_api.md` - Our specific API surface area, struct definitions, open questions
- `docs/idioms.md` - Zig idioms translated for high-level language developers

**When in doubt:**
1. Check `docs/zig.md` for how Zig does things
2. Check `docs/zig_api.md` for what APIs we're using
3. Check `docs/idioms.md` for "is this idiomatic?"
4. Update these docs as we learn more
5. The stdlib source at `/opt/zig/lib/std/` is the ultimate truth

## Target Versions

- **Zig:** 0.16.0-dev (master branch)
- **Linux kernel:** 6.0+ (ublk support), 6.8+ recommended (IOCTL encoding)
- **Architecture:** x86_64 initially (memory barriers are arch-specific)

## What go-ublk Teaches Us (Protocol Knowledge)

The Go code is our source of truth for the ublk **protocol**, not code style.

### Kernel ABI Structures (must match exactly)

```
UblksrvCtrlCmd     - 32 bytes, control commands in SQE cmd area
UblksrvCtrlDevInfo - 64 bytes, device info
UblksrvIODesc      - 24 bytes, mmap'd descriptor array
UblksrvIOCmd       - 16 bytes, IO commands in SQE cmd area
UblkParams         - Device parameters (basic, discard, devt, zoned)
```

### io_uring Setup

- SQE128 mode (128-byte SQEs, 80-byte cmd area at bytes 48-127)
- CQE32 mode (32-byte CQEs)
- URING_CMD opcode for ublk operations
- Memory barriers matter (sfence before tail, mfence before reading CQEs)

### Device Lifecycle

```
Open /dev/ublk-control -> ADD_DEV -> SET_PARAMS -> (setup queues) -> START_DEV
                                                                         |
IO loop: FETCH_REQ -> process -> COMMIT_AND_FETCH_REQ -------------------+
                                                                         |
                                              STOP_DEV -> DEL_DEV <------+
```

### ioctl Encoding (kernel 6.11+)

```
cmd = (dir << 30) | (size << 16) | ('u' << 8) | nr
```

## Reference Files in go-ublk

When you need protocol details:
- `.go-ublk-ref/internal/uapi/constants.go` - Commands, flags, limits
- `.go-ublk-ref/internal/uapi/structs.go` - Struct definitions
- `.go-ublk-ref/internal/ctrl/control.go` - Control flow
- `.go-ublk-ref/internal/queue/runner.go` - IO state machine
- `.go-ublk-ref/internal/uring/minimal.go` - io_uring usage

## Development

```bash
zig build              # Build
zig build test         # Run tests
make vm-simple-e2e     # Build, copy to VM, and run e2e test
```

## VM Testing

**IMPORTANT:** Never SSH to the VM directly. Always use `make` targets:

```bash
make vm-check          # Verify VM configuration
make vm-copy           # Build and copy binary to VM
make vm-simple-e2e     # Full e2e test on VM
make vm-reset          # Hard reset VM if stuck
make vm-trace          # Dump kernel trace from VM
```

VM configuration is in `Makefile.local` (gitignored).

## Workflow

**Commit early, commit often.** After any meaningful chunk of work, do a single-sentence commit and push. Don't batch up changes.

## Notes

- Device creation requires root or CAP_SYS_ADMIN
- See TODO.md Phase 0 (Zig Bootcamp) for learning plan
