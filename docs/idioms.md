# Zig Idioms for High-Level Language Developers

A translation guide for developers coming from Go, Java, C#, or similar GC-managed languages. Examples focus on patterns used in this codebase.

## Common Pattern: Thread Coordination

This pattern appears throughout the codebase:

```zig
var ctx = QueueContext{
    .queue = &queue,
    .ready = std.atomic.Value(bool).init(false),
    .stop = std.atomic.Value(bool).init(false),
};

while (!ctx.ready.load(.acquire)) {
    std.Thread.yield() catch {};
}
```

Breaking it down:

**`var ctx = QueueContext{ .field = value, ... }`**
- Struct initialization with named fields
- All fields must be initialized (no automatic zero values)
- Go: `ctx := QueueContext{Field: value, ...}`
- Java/C#: `var ctx = new QueueContext { Field = value, ... }`

**`std.atomic.Value(bool).init(false)`**
- Generic atomic type, initialized to `false`
- `std.atomic.Value(bool)` is the type
- `.init(false)` creates an instance with that value
- Go: `var ready atomic.Bool`
- Java: `AtomicBoolean ready = new AtomicBoolean(false)`

**`ctx.ready.load(.acquire)`**
- Atomic load with explicit memory ordering
- `.acquire` ensures visibility of prior writes from other threads
- Most high-level languages hide memory orderings (use sequential consistency)

**`std.Thread.yield() catch {}`**
- Yield CPU to other threads
- `catch {}` silently discards errors (yield can fail on some platforms)
- Go: `runtime.Gosched()`
- Java: `Thread.yield()`

---

## Memory Orderings

High-level languages typically use sequential consistency for atomics. Zig exposes hardware reality:

| Ordering | Meaning | Use Case |
|----------|---------|----------|
| `.relaxed` | No ordering guarantees | Counters, statistics |
| `.acquire` | Subsequent reads can't move before this | Reading shared state |
| `.release` | Prior writes can't move after this | Publishing shared state |
| `.acq_rel` | Both acquire and release | Read-modify-write |
| `.seq_cst` | Full sequential consistency | When in doubt |

**Producer-consumer pattern:**
```zig
// Producer: write data, then signal
@atomicStore(u32, &data, 42, .relaxed);
ctx.ready.store(true, .release);       // release barrier

// Consumer: wait for signal, then read
while (!ctx.ready.load(.acquire)) {}   // acquire barrier
const value = @atomicLoad(u32, &data, .relaxed);
```

The acquire/release pair creates "happens-before" - the consumer sees all writes the producer made before the release.

---

## Struct Initialization: No Zero Values

**High-level languages:** Automatic default values
```go
// Go: x=0, s=""
var f Foo

// Java/C#: fields get default values
Foo f = new Foo();
```

**Zig:** All fields must be explicit
```zig
const Foo = struct {
    x: i32,
    s: []const u8,
};

// Must specify everything
var f = Foo{ .x = 0, .s = "" };

// OR use std.mem.zeroes for C-like zeroing
var f = std.mem.zeroes(Foo);

// OR use std.mem.zeroInit with some fields set
var f = std.mem.zeroInit(Foo, .{ .x = 42 });  // s gets zeroed
```

---

## Error Handling: try/catch

**Go:**
```go
result, err := doThing()
if err != nil {
    return err
}
```

**Java/C#:**
```java
try {
    result = doThing();
} catch (Exception e) {
    throw e;
}
```

**Zig:**
```zig
// Propagate error (like throws in Java)
const result = try doThing();

// Handle error explicitly
const result = doThing() catch |err| {
    return err;
};

// Ignore error (like empty catch block)
std.Thread.yield() catch {};

// Switch on error type
const fd = open(path) catch |err| switch (err) {
    error.FileNotFound => return null,
    else => return err,
};
```

---

## defer and errdefer

**High-level languages:** `defer`/`finally` always runs
```go
f, _ := os.Open(path)
defer f.Close()  // always runs
```

**Zig:** Two variants
```zig
const f = try std.posix.open(path, .{}, 0);
defer std.posix.close(f);      // Always runs on scope exit

// errdefer only runs if function returns error!
const ring = try IoUring128.init(32);
errdefer ring.deinit();        // Only on error path
return Controller{ .ring = ring };  // Success: errdefer skipped
```

**Resource cleanup during init:**
```zig
pub fn init() !MyThing {
    const a = try allocateA();
    errdefer freeA(a);          // Only if we fail after this

    const b = try allocateB();
    errdefer freeB(b);          // Only if we fail after this

    const c = try allocateC();  // If this fails, b and a freed

    return MyThing{ .a = a, .b = b, .c = c };  // Success: no cleanup
}
```

This pattern replaces complex try-catch-finally blocks with linear code.

---

## Anonymous Structs: The `.{}` Mystery

**What is `.{}`?**

An anonymous struct literal with inferred type. Appears everywhere:

```zig
// Empty anonymous struct (format args with no values)
std.debug.print("hello\n", .{});

// Anonymous struct with values
std.debug.print("x={d} y={s}\n", .{ 42, "hello" });

// Anonymous struct for partial initialization
const params = std.mem.zeroInit(MyStruct, .{ .field = value });
```

This is Zig's way of passing structured data inline, similar to:
- Go: `struct{}{}` or anonymous structs
- C#: Anonymous types `new { Field = value }`
- Java: No direct equivalent (would need a class)

---

## Generics: comptime Parameters

**High-level languages:** Runtime generics or type erasure
```go
func Process[T any](items []T) { ... }
```
```java
public <T> void process(List<T> items) { ... }
```

**Zig:** Compile-time parameters (zero runtime cost)
```zig
fn process(comptime T: type, items: []T) void { ... }
process(u32, my_slice);

// Return a type (type-level function)
fn ArrayList(comptime T: type) type {
    return struct {
        items: []T,
    };
}
var list = ArrayList(u32){};
```

**In this codebase:**
```zig
pub fn getCmd(self: *IoUringSqe128, comptime T: type) *T {
    const cmd_ptr: *[80]u8 = @ptrCast(&self.addr3_or_cmd);
    return @ptrCast(@alignCast(cmd_ptr));
}

// Usage - type is compile-time parameter
const cmd = sqe.getCmd(UblksrvCtrlCmd);
```

---

## Type Casting: Explicit Builtins

**High-level languages:** Implicit or simple syntax
```go
x := int(someInt32)
y := (*MyType)(unsafe.Pointer(p))
```

**Zig:** Specific builtins for each conversion
```zig
// Numeric conversion (checked)
const x: i32 = 42;
const y: u64 = @as(u64, @intCast(x));

// Pointer casting (for FFI/kernel ABI)
const ptr: *[80]u8 = @ptrCast(&self.addr3_or_cmd);
const typed: *UblksrvCtrlCmd = @ptrCast(@alignCast(ptr));

// Int to enum
const op: CtrlCmd = @enumFromInt(4);
```

**`@alignCast` requirement:** When casting to a more-aligned type:
```zig
// u8 is 1-byte aligned, UblksrvCtrlCmd is 8-byte aligned
const raw: *u8 = &buffer[0];
const typed: *UblksrvCtrlCmd = @ptrCast(@alignCast(raw));
```

---

## Pointers and Slices

**High-level languages:** References and arrays
- Go: `[]int` (slice), `[5]int` (array)
- Java/C#: Arrays are reference types

**Zig:** Multiple pointer types
```zig
const single: *u32 = &value;         // Single-item pointer
const many: [*]u32 = &array[0];      // Many-item pointer (C-style)
const slice: []u32 = array[0..10];   // Slice (pointer + length)
const array: [5]u32 = .{1,2,3,4,5};  // Fixed-size array
```

**Key difference:** Zig slices have no capacity (unlike Go). For dynamic arrays:
```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append(42);
```

---

## The `volatile` Keyword

**High-level languages:** Use atomics for concurrent access

**Zig:** `volatile` for memory-mapped IO / kernel communication
```zig
// Memory that kernel can modify
descriptors: []volatile UblksrvIoDesc,

// Reading volatile - compiler won't cache or optimize away
const desc = self.descriptors[tag];
```

Use `volatile` for: mmap'd kernel memory, hardware registers, shared memory regions.

---

## Wrapping Arithmetic

**High-level languages:** Overflow wraps silently or throws

**Zig:** Overflow is illegal by default
```zig
// Normal (panics on overflow in safe mode)
const x = a + b;

// Wrapping operators (explicit wrap)
const x = a +% b;  // Wraps on overflow
const x = a -% b;  // Wraps on underflow

// Ring buffer indices use wrapping
const next = self.sqe_tail +% 1;
```

---

## The `undefined` Value

**High-level languages:** Default values everywhere

**Zig:** `undefined` means explicitly uninitialized
```zig
// Will be immediately overwritten
var sqe: IoUringSqe128 = undefined;
@memset(@as(*[128]u8, @ptrCast(&sqe)), 0);

// Output parameter pattern
var cqes: [64]IoUringCqe32 = undefined;
const count = self.ring.copyCqes(&cqes);  // Fills cqes
```

---

## Function Pointers / Callbacks

**High-level languages:** First-class functions, lambdas
```go
type Handler func(q *Queue, tag uint16) int
```

**Zig:** Explicit function pointer types
```zig
// Function pointer type
handler: *const fn (queue: *Queue, tag: u16, desc: UblksrvIoDesc, buffer: []u8) i32

// Passing a function (just use the name)
_ = queue.processCompletions(nullHandler);
```

---

## Idiom Assessment: This Codebase

### Patterns Done Right

1. **`errdefer` chains** - Clean resource cleanup during init
2. **Comptime size checks** - Compile-time validation of kernel ABI
3. **`extern struct`** - C-compatible layout for kernel FFI
4. **Error sets** - Organized, specific error types
5. **Atomic orderings** - Correct acquire/release patterns

### Patterns That Look Strange But Are Correct

1. **`.{}` everywhere** - Normal Zig, anonymous structs are common
2. **`catch {}` for ignored errors** - Intentional, like empty catch blocks
3. **`@ptrCast(@alignCast(...))` chains** - Standard for low-level pointer work
4. **`+%` operators** - Required for ring buffer wrap-around

### Could Improve

1. ~~**File organization** - root.zig should be split~~ - DONE (uapi.zig, params.zig, ring.zig, control.zig, queue.zig)
2. ~~**Magic numbers** - IO operation codes should be named constants~~ - DONE (IoOp enum in uapi.zig)
3. **Logging** - `std.debug.print` is fine for dev, `std.log` for production
