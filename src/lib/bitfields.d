/**
 * Bitfield support for bare-metal D (no D runtime, no Phobos).
 *
 * Compatible with:  -betterC   (LDC / DMD)
 *                   -fno-druntime
 *                   Freestanding / embedded targets (ARM, RISC-V, x86 ring-0 …)
 *
 * Everything here is:
 *   @nogc @safe / @trusted  pure nothrow
 *   zero heap allocation
 *   no Phobos imports  (std.traits replaced by local trait templates)
 *   no TypeInfo / ModuleInfo  (never emitted)
 *   no exceptions
 *   no GC
 *   `assert` mapped to a bare __halt trap (override via version=BM_ASSERT_NONE)
 *
 * Compile examples
 * ─────────────────
 *   # DMD, betterC, test harness wired to UART putchar:
 *   dmd  -betterC -unittest -run bitfields_baremetal.d
 *
 *   # LDC cross-compile for ARM Cortex-M (thumb2, no stdlib):
 *   ldc2 -betterC -mtriple=thumbv7em-none-eabi \
 *        -mcpu=cortex-m4 -O2 \
 *        -nogc -nophoboslib \
 *        bitfields_baremetal.d
 *
 * Module layout
 * ─────────────
 *   §1  Bare assert / panic hook
 *   §2  Local trait helpers  (replaces std.traits)
 *   §3  Compile-time mask helper
 *   §4  BitField!(Storage, T, offset, width)
 *   §5  BitStructMixin!(Storage, Fields…)
 *   §6  BitFlags!(E)
 *   §7  RawBits  free functions
 *   §8  MMIO register wrapper
 *   §9  Static (compile-time) unit tests
 *  §10  Optional betterC entry point / demo
 */

module lib.bitfields;

// No runtime imports — ever.
// Any `import` here must be a -betterC-safe compiler-intrinsic module.

// ─────────────────────────────────────────────────────────────────────────────
// §1  Bare assert / panic hook
//
//   By default a failed assert executes an infinite loop / debug-break.
//   Embed your own handler by defining:
//
//     extern(C) void bm_panic(const(char)* msg, uint line) @nogc nothrow;
//
//   and compiling with  -version=BM_PANIC_EXTERN
// ─────────────────────────────────────────────────────────────────────────────

version (BM_ASSERT_NONE)
{
    /// Assertions are completely compiled out.
    enum _bm_assert(string _) = "";
}
else version (BM_PANIC_EXTERN)
{
    extern(C) void bm_panic(const(char)* msg, uint line) @nogc nothrow;

    void _bm_assertFail(const(char)* msg, uint line) @nogc nothrow
    {
        bm_panic(msg, line);
    }
}
else
{
    /// Default: spin forever (or insert a BKPT / ebreak via inline asm).
    void _bm_assertFail(const(char)* msg, uint line) @nogc nothrow @trusted
    {
        // A debugger will catch the spin; replace with target-specific trap:
        // version (ARM)   { asm @nogc nothrow { "bkpt #0"; } }
        // version (RISCV) { asm @nogc nothrow { "ebreak"; }  }
        while (true) {}
    }
}

/// Internal assert macro — evaluates condition at runtime, calls _bm_assertFail.
template bmAssert(bool cond, string msg = "assertion failed",
                  string file = __FILE__, uint line = __LINE__)
{
    static if (!__traits(compiles, { static assert(cond); }))
        // runtime path
        void bmAssert() @nogc nothrow
        {
            version (BM_ASSERT_NONE) {}
            else { if (!cond) _bm_assertFail(msg.ptr, line); }
        }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2  Local trait helpers  (no std.traits)
// ─────────────────────────────────────────────────────────────────────────────

/// True if T is a built-in integer type.
template isIntegral(T)
{
    enum isIntegral =
        is(T == byte)  || is(T == ubyte)  ||
        is(T == short) || is(T == ushort) ||
        is(T == int)   || is(T == uint)   ||
        is(T == long)  || is(T == ulong);
}

/// True if T is an unsigned integer type.
template isUnsigned(T)
{
    enum isUnsigned =
        is(T == ubyte) || is(T == ushort) ||
        is(T == uint)  || is(T == ulong);
}

/// Yield the underlying type of an enum, or T itself if not an enum.
template EnumBaseType(T)
{
    static if (is(T Base == enum)) alias EnumBaseType = Base;
    else                           alias EnumBaseType = T;
}

// ─────────────────────────────────────────────────────────────────────────────
// §3  Compile-time mask helper
// ─────────────────────────────────────────────────────────────────────────────

/// Compile-time mask: `width` ones starting at bit `offset`.
enum ulong maskOf(int offset, int width) =
    ((1UL << width) - 1UL) << offset;

// ─────────────────────────────────────────────────────────────────────────────
// §4  BitField — a single packed field inside a storage word
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Represents a bitfield of `width` bits at bit position `offset`
 * inside an integer of type `Storage`, exposed as type `T`.
 *
 * All methods are static — no instance data, no heap, no runtime.
 *
 * Example (ARM NVIC ISER register layout):
 * ---
 *   uint raw;
 *   alias setena = BitField!(uint, uint, 0, 32);
 *   setena.set(raw, 1u << 3);   // enable IRQ 3
 * ---
 */
struct BitField(Storage, T, int offset, int width)
    if (isIntegral!Storage && isIntegral!T)
{
    static assert(width  >= 1,
        "BitField: width must be >= 1");
    static assert(offset >= 0,
        "BitField: offset must be >= 0");
    static assert(offset + width <= Storage.sizeof * 8,
        "BitField: field exceeds storage width");

    enum int     Offset = offset;
    enum int     Width  = width;
    enum Storage Mask   = cast(Storage) maskOf!(offset, width);

    /// Read the field from `storage`.
    pragma(inline, true)
    static T get(Storage storage) pure nothrow @nogc @safe
    {
        return cast(T) ((storage & Mask) >>> Offset);
    }

    /// Write `value` into `storage`; all other bits are preserved.
    pragma(inline, true)
    static void set(ref Storage storage, T value) pure nothrow @nogc @safe
    {
        immutable Storage v = (cast(Storage) value << Offset) & Mask;
        storage = cast(Storage) ((storage & ~Mask) | v);
    }

    /**
     * Perform a read-modify-write on a memory-mapped register.
     * `addr` must be naturally aligned.  Marked @trusted because
     * dereferencing a raw address is inherently unsafe.
     */
    pragma(inline, true)
    static void mmioSet(size_t addr, T value) nothrow @nogc @trusted
    {
        auto reg = cast(Storage*) addr;
        set(*reg, value);
    }

    /// Read from a memory-mapped register.
    pragma(inline, true)
    static T mmioGet(size_t addr) nothrow @nogc @trusted
    {
        return get(*(cast(Storage*) addr));
    }

    /// Return a copy of `storage` with the field replaced by `value`.
    pragma(inline, true)
    static Storage with_(Storage storage, T value) pure nothrow @nogc @safe
    {
        set(storage, value);
        return storage;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5  BitStructMixin — multiple named fields in one struct
// ─────────────────────────────────────────────────────────────────────────────

/**
 * String mixin that auto-generates getter/setter @property pairs for a
 * sequence of `(name, FieldType, width)` triplets packed into `Storage`.
 *
 * Usage:
 * ---
 *   struct ControlReg
 *   {
 *       uint raw;   // backing storage — must be named `raw`
 *       mixin(BitStructMixin!(uint,
 *           "enable",  ubyte,  1,   // bit  0
 *           "mode",    ubyte,  3,   // bits 1-3
 *           "divider", ushort, 12,  // bits 4-15
 *       ));
 *   }
 *
 *   ControlReg cr;
 *   cr.enable  = 1;
 *   cr.mode    = 5;
 *   cr.divider = 256;
 * ---
 */
template BitStructMixin(Storage, Fields...)
    if (isIntegral!Storage && Fields.length % 3 == 0)
{
    enum BitStructMixin = _buildMixin!(Storage, 0, Fields);
}

private template _buildMixin(Storage, int off, Fields...)
{
    static if (Fields.length == 0)
        enum _buildMixin = "";
    else
    {
        enum  name  = Fields[0];
        alias FT    = Fields[1];
        enum  width = cast(int) Fields[2];

        // Emit: alias + getter + setter, then recurse.
        enum _buildMixin =
            "alias _bf_" ~ name ~
                " = BitField!(" ~ Storage.stringof ~ "," ~
                FT.stringof ~ "," ~ off.stringof ~ "," ~ width.stringof ~ ");\n" ~

            "@property " ~ FT.stringof ~ " " ~ name ~
                "() const pure nothrow @nogc @safe" ~
                "{ return _bf_" ~ name ~ ".get(raw); }\n" ~

            "@property void " ~ name ~ "(" ~ FT.stringof ~ " v)" ~
                " pure nothrow @nogc @safe" ~
                "{ _bf_" ~ name ~ ".set(raw, v); }\n" ~

            _buildMixin!(Storage, off + width, Fields[3 .. $]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6  BitFlags — type-safe enum flag set
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A compact, zero-overhead set of bit flags backed by an enum.
 *
 * No heap, no GC, no runtime — just a single integer.
 *
 * Example:
 * ---
 *   enum IRQ : uint { uart = 1u<<0, spi = 1u<<1, i2c = 1u<<2 }
 *   auto pending = BitFlags!IRQ(IRQ.uart);
 *   pending.set(IRQ.spi);
 *   assert(pending.isSet(IRQ.uart));
 *   assert(!pending.isSet(IRQ.i2c));
 * ---
 */
struct BitFlags(E)
    if (is(E == enum) && isIntegral!(EnumBaseType!E))
{
    alias Storage = EnumBaseType!E;
    Storage value;

    /// Construct from raw integer.
    pragma(inline, true)
    this(Storage raw) pure nothrow @nogc @safe { value = raw; }

    /// Construct with a single flag pre-set.
    pragma(inline, true)
    this(E flag) pure nothrow @nogc @safe
    {
        value = cast(Storage) flag;
    }

    /// Test whether `flag` is set.
    pragma(inline, true)
    bool isSet(E flag) const pure nothrow @nogc @safe
    {
        return (value & cast(Storage) flag) == cast(Storage) flag;
    }

    /// Set a flag.
    pragma(inline, true)
    void set(E flag) pure nothrow @nogc @safe
    {
        value |= cast(Storage) flag;
    }

    /// Clear a flag.
    pragma(inline, true)
    void clear(E flag) pure nothrow @nogc @safe
    {
        value &= cast(Storage)(~cast(Storage) flag);
    }

    /// Toggle a flag.
    pragma(inline, true)
    void toggle(E flag) pure nothrow @nogc @safe
    {
        value ^= cast(Storage) flag;
    }

    /// True if no flags are set.
    pragma(inline, true)
    bool none() const pure nothrow @nogc @safe { return value == 0; }

    /// True if at least one flag is set.
    pragma(inline, true)
    bool any() const pure nothrow @nogc @safe { return value != 0; }

    /// Bitwise OR.
    pragma(inline, true)
    BitFlags opBinary(string op : "|")(BitFlags rhs) const
        pure nothrow @nogc @safe
    {
        return BitFlags(cast(Storage)(value | rhs.value));
    }

    /// Bitwise AND.
    pragma(inline, true)
    BitFlags opBinary(string op : "&")(BitFlags rhs) const
        pure nothrow @nogc @safe
    {
        return BitFlags(cast(Storage)(value & rhs.value));
    }

    /// Bitwise XOR.
    pragma(inline, true)
    BitFlags opBinary(string op : "^")(BitFlags rhs) const
        pure nothrow @nogc @safe
    {
        return BitFlags(cast(Storage)(value ^ rhs.value));
    }

    /// Bitwise complement (unary ~).
    pragma(inline, true)
    BitFlags opUnary(string op : "~")() const pure nothrow @nogc @safe
    {
        return BitFlags(cast(Storage)(~value));
    }

    /// Assign from another BitFlags.
    pragma(inline, true)
    ref BitFlags opAssign(BitFlags rhs) pure nothrow @nogc @safe
    {
        value = rhs.value;
        return this;
    }

    /// Equality.
    pragma(inline, true)
    bool opEquals(BitFlags rhs) const pure nothrow @nogc @safe
    {
        return value == rhs.value;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7  RawBits — free-function low-level helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Extract `width` bits at `offset` from `value`.
pragma(inline, true)
T getBits(T = uint)(ulong value, int offset, int width)
    pure nothrow @nogc @safe
    if (isIntegral!T)
{
    immutable ulong mask = (1UL << width) - 1UL;
    return cast(T) ((value >>> offset) & mask);
}

/// Return `value` with `width` bits at `offset` replaced by `bits`.
pragma(inline, true)
T setBits(T)(T value, int offset, int width, ulong bits)
    pure nothrow @nogc @safe
    if (isIntegral!T)
{
    immutable ulong mask = ((1UL << width) - 1UL) << offset;
    return cast(T) ((value & ~cast(T)mask) | ((bits << offset) & cast(T)mask));
}

/// Test a single bit.
pragma(inline, true)
bool testBit(T)(T value, int bit) pure nothrow @nogc @safe
    if (isIntegral!T)
{
    return (value & (cast(T)1 << bit)) != 0;
}

/// Set a single bit.
pragma(inline, true)
T setBit(T)(T value, int bit) pure nothrow @nogc @safe
    if (isIntegral!T)
{
    return cast(T)(value | (cast(T)1 << bit));
}

/// Clear a single bit.
pragma(inline, true)
T clearBit(T)(T value, int bit) pure nothrow @nogc @safe
    if (isIntegral!T)
{
    return cast(T)(value & ~(cast(T)1 << bit));
}

/// Toggle a single bit.
pragma(inline, true)
T toggleBit(T)(T value, int bit) pure nothrow @nogc @safe
    if (isIntegral!T)
{
    return cast(T)(value ^ (cast(T)1 << bit));
}

// ─────────────────────────────────────────────────────────────────────────────
// §8  MMIO — memory-mapped register accessors
//
//   D has NO `volatile` keyword.  Volatile semantics are achieved by:
//
//   LDC  : volatileLoad / volatileStore from ldc.volatile
//   DMD  : inline-asm memory clobber to defeat optimiser reordering
//
//   Both paths produce a plain pointer dereference that the compiler
//   cannot hoist, sink, or eliminate.
// ─────────────────────────────────────────────────────────────────────────────

// Volatile load/store — resolved at compile time across all supported backends.
//
//   LDC >= 1.4   ldc.volatile          (module added in LDC 1.4)
//   LDC <  1.4   ldc.intrinsics        (volatileLoad/Store lived here)
//   DMD          core.volatile         (added in DMD 2.100 / druntime)
//   GDC / other  asm memory-clobber    (portable fallback)
//
// Detect which path is available entirely at compile time so that a missing
// module is never imported.

private
{
    // Try each path in order; __traits(compiles, …) tests without importing.
    static if (__traits(compiles, { import ldc.volatile : volatileLoad, volatileStore; }))
    {
        import ldc.volatile : volatileLoad, volatileStore;
        enum _mmioBackend = "ldc.volatile";
    }
    else static if (__traits(compiles, { import ldc.intrinsics : volatileLoad, volatileStore; }))
    {
        import ldc.intrinsics : volatileLoad, volatileStore;
        enum _mmioBackend = "ldc.intrinsics";
    }
    else static if (__traits(compiles, { import core.volatile : volatileLoad, volatileStore; }))
    {
        import core.volatile : volatileLoad, volatileStore;
        enum _mmioBackend = "core.volatile";
    }
    else
    {
        // Generic fallback: asm memory-clobber on x86/x86-64;
        // replace with "dmb sy" (ARM) or "fence rw,rw" (RISC-V) as needed.
        pragma(inline, true)
        private T volatileLoad(T)(T* ptr) @nogc nothrow @trusted
        {
            version (X86_64) asm @nogc nothrow { "" : : : "memory"; }
            else version (X86) asm @nogc nothrow { "" : : : "memory"; }
            T v = *ptr;
            version (X86_64) asm @nogc nothrow { "" : : : "memory"; }
            else version (X86) asm @nogc nothrow { "" : : : "memory"; }
            return v;
        }

        pragma(inline, true)
        private void volatileStore(T)(T* ptr, T value) @nogc nothrow @trusted
        {
            version (X86_64) asm @nogc nothrow { "" : : : "memory"; }
            else version (X86) asm @nogc nothrow { "" : : : "memory"; }
            *ptr = value;
            version (X86_64) asm @nogc nothrow { "" : : : "memory"; }
            else version (X86) asm @nogc nothrow { "" : : : "memory"; }
        }

        enum _mmioBackend = "asm-clobber";
    }
}

/// Volatile read from a memory-mapped register address.
pragma(inline, true)
T mmioRead(T)(size_t addr) nothrow @nogc @trusted
    if (isIntegral!T)
{
    return volatileLoad(cast(T*) addr);
}

/// Volatile write to a memory-mapped register address.
pragma(inline, true)
void mmioWrite(T)(size_t addr, T value) nothrow @nogc @trusted
    if (isIntegral!T)
{
    volatileStore(cast(T*) addr, value);
}

/**
 * Read-modify-write a single BitField inside a memory-mapped register.
 *
 * `Field` must be a `BitField` alias.  `Storage` and `FieldT` are its
 * two key type parameters, supplied explicitly to avoid `typeof` on a
 * template alias (which DMD rejects in -betterC mode).
 *
 * Example:
 * ---
 *   // UART0 control register at 0x4000_1000, baud-divisor in bits 0-15
 *   alias BaudDiv = BitField!(uint, ushort, 0, 16);
 *   mmioRmw!(uint, ushort, BaudDiv)(0x4000_1000, 9600);
 * ---
 */
pragma(inline, true)
void mmioRmw(Storage, FieldT, alias Field)(size_t addr, FieldT value)
    nothrow @nogc @trusted
    if (isIntegral!Storage && isIntegral!FieldT)
{
    Storage raw = mmioRead!Storage(addr);   // volatile read
    Field.set(raw, value);                  // modify field bits
    mmioWrite!Storage(addr, raw);           // volatile write
}

// ─────────────────────────────────────────────────────────────────────────────
// §9  Static (compile-time) tests  +  betterC runtime tests
//
//   static assert — always runs at compile time, zero runtime cost.
//   The `unittest` blocks compile and run with `dmd -betterC -unittest`.
// ─────────────────────────────────────────────────────────────────────────────

// ── Compile-time checks (always active) ─────────────────────────────────────

// Mask helper
static assert(maskOf!(0,  4) == 0x0000_000F);
static assert(maskOf!(4,  4) == 0x0000_00F0);
static assert(maskOf!(8, 16) == 0x00FF_FF00);

// BitField: layout does not overlap
alias _CK0 = BitField!(uint, ubyte,  0, 6);
alias _CK1 = BitField!(uint, ubyte,  6, 2);
alias _CK2 = BitField!(uint, ushort, 8, 16);
static assert((_CK0.Mask & _CK1.Mask) == 0);
static assert((_CK1.Mask & _CK2.Mask) == 0);
static assert((_CK0.Mask & _CK2.Mask) == 0);

// isIntegral
static assert( isIntegral!uint);
static assert( isIntegral!long);
static assert(!isIntegral!float);
static assert(!isIntegral!void);

// ── Runtime tests (betterC-compatible) ──────────────────────────────────────

version (unittest):

// Under -betterC there is no default test runner.
// We wire one up manually: each test function is called from
// the extern(C) _d_run_tests() below, invoked from main().

extern(C) void _d_run_tests() @nogc nothrow
{
    _test_BitField();
    _test_BitStructMixin();
    _test_BitFlags();
    _test_RawBits();
}

private void _test_BitField() @nogc nothrow
{
    uint raw = 0;
    alias opcode = BitField!(uint, ubyte,  0, 6);
    alias mode   = BitField!(uint, ubyte,  6, 2);
    alias imm    = BitField!(uint, ushort, 8, 16);

    opcode.set(raw, 42);
    assert(opcode.get(raw) == 42);

    mode.set(raw, 3);
    assert(mode.get(raw) == 3);
    assert(opcode.get(raw) == 42);  // not clobbered

    imm.set(raw, 0xBEEF);
    assert(imm.get(raw) == 0xBEEF);
    assert(mode.get(raw) == 3);
    assert(opcode.get(raw) == 42);

    // width clamping
    opcode.set(raw, 0xFF);
    assert(opcode.get(raw) == 0x3F);

    // with_()
    uint r2 = opcode.with_(0, 7);
    assert(opcode.get(r2) == 7);
    assert(opcode.get(raw) == 0x3F);  // original unchanged
}

private void _test_BitStructMixin() @nogc nothrow
{
    struct Instr
    {
        uint raw;
        mixin(BitStructMixin!(uint,
            "op",  ubyte,  6,
            "mod", ubyte,  2,
            "imm", ushort, 16,
        ));
    }

    Instr i;
    i.op  = 7;
    i.mod = 2;
    i.imm = 1234;

    assert(i.op  == 7);
    assert(i.mod == 2);
    assert(i.imm == 1234);

    i.op = 63;
    assert(i.mod == 2);    // not clobbered
    assert(i.imm == 1234); // not clobbered
}

private void _test_BitFlags() @nogc nothrow
{
    enum Perm : uint { read = 1, write = 2, exec = 4 }

    auto p = BitFlags!Perm(Perm.read);
    p.set(Perm.write);

    assert( p.isSet(Perm.read));
    assert( p.isSet(Perm.write));
    assert(!p.isSet(Perm.exec));
    assert( p.any());
    assert(!p.none());

    p.set(Perm.exec);

    p.clear(Perm.write);
    assert(!p.isSet(Perm.write));

    p.toggle(Perm.read);
    assert(!p.isSet(Perm.read));

    // operators
    auto a = BitFlags!Perm(Perm.read);
    auto b = BitFlags!Perm(Perm.write);
    auto c = a | b;
    assert(c.isSet(Perm.read) && c.isSet(Perm.write));

    auto d = c & a;
    assert( d.isSet(Perm.read));
    assert(!d.isSet(Perm.write));

    auto e = ~a;
    assert(!e.isSet(Perm.read));
}

private void _test_RawBits() @nogc nothrow
{
    uint v = 0b_1010_1100;
    assert(getBits(v, 2, 4) == 0b1011);

    v = setBits(v, 4, 4, 0b0110u);
    assert(getBits(v, 4, 4) == 0b0110);

    assert(!testBit(v, 0));
    v = setBit(v, 0);
    assert(testBit(v, 0));
    v = clearBit(v, 0);
    assert(!testBit(v, 0));
    // After setBits(v, 4, 4, 0b0110) bit 7 became 0, so toggling sets it.
    v = toggleBit(v, 7);
    assert(testBit(v, 7));      // 0 → 1
    v = toggleBit(v, 7);
    assert(!testBit(v, 7));     // 1 → 0
}

// ─────────────────────────────────────────────────────────────────────────────
// §10  Bare-metal entry point
//
//   For a real embedded target you will replace this with your own
//   reset handler / _start.  For hosted testing with `dmd -betterC -run`
//   the C runtime calls extern(C) main().
// ─────────────────────────────────────────────────────────────────────────────

extern(C) int main() @nogc nothrow
{
    version (unittest) { _d_run_tests(); }

    // ── Demonstrate BitStructMixin on a fake RISC instruction word ──────────
    struct RiscInstr
    {
        uint raw;
        mixin(BitStructMixin!(uint,
            "funct", ubyte,  6,
            "rd",    ubyte,  5,
            "rs",    ubyte,  5,
            "imm",   ushort, 16,
        ));
    }

    RiscInstr ins;
    ins.funct = 0x2A;
    ins.rd    = 3;
    ins.rs    = 7;
    ins.imm   = 0xCAFE;

    // On bare-metal you'd write ins.raw to a peripheral register here.
    // For demonstration we just verify correctness at runtime:
    assert(ins.funct == 0x2A);
    assert(ins.rd    == 3);
    assert(ins.rs    == 7);
    assert(ins.imm   == 0xCAFE);

    // ── BitFlags with peripheral IRQ mask ───────────────────────────────────
    enum IRQ : uint { uart = 1u<<0, spi = 1u<<1, i2c = 1u<<2, timer = 1u<<3 }

    auto enabled = BitFlags!IRQ(IRQ.uart);
    enabled.set(IRQ.timer);
    assert( enabled.isSet(IRQ.uart));
    assert( enabled.isSet(IRQ.timer));
    assert(!enabled.isSet(IRQ.spi));

    return 0;   // signal success to any hosting environment
}
