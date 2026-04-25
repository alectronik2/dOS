module hal.gdt;

/* ------------------------------------------------------------------ */
/* Structures                                                           */
/* ------------------------------------------------------------------ */

/**
 * GDTR — the 10-byte operand loaded by the LGDT instruction
 * in 64-bit mode (2-byte limit + 8-byte linear base).
 */
align(1) struct GDTR
{
align(1):
    ushort limit;
    ulong  base;
}
static assert(GDTR.sizeof == 10, "GDTR must be exactly 10 bytes");

align(1) struct TSS64
{
align(1):
    u32 reserved0;
    u64 rsp0;
    u64 rsp1;
    u64 rsp2;
    u64 reserved1;
    u64 ist1;
    u64 ist2;
    u64 ist3;
    u64 ist4;
    u64 ist5;
    u64 ist6;
    u64 ist7;
    u64 reserved2;
    u16 reserved3;
    u16 iopb_offset;
}
static assert(TSS64.sizeof == 104, "TSS64 must be exactly 104 bytes");

/* ------------------------------------------------------------------ */
/* Selector constants (for use in IDT and TSS setup)                    */
/* ------------------------------------------------------------------ */
const KERNEL_CS = 0x08;
const KERNEL_DS = 0x10;
const USER_DS   = 0x23;   /* 0x20 | RPL 3 */
const USER_CS   = 0x2B;   /* 0x28 | RPL 3 */
const TSS_CPU0  = 0x30;

/* ------------------------------------------------------------------ */
/* Storage                                                              */
/* ------------------------------------------------------------------ */
private enum NUM_ENTRIES = 8;

align(16) __gshared ulong[NUM_ENTRIES] gdt_table;
align(4)  __gshared GDTR                  gdt_ptr;
align(16) __gshared TSS64                 tss;
align(16) __gshared ubyte[4096]           privilege_stack;
align(16) __gshared ubyte[4096]           double_fault_stack;

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

private ulong
make_entry(uint base, uint limit, ubyte access, ubyte flags)
{
    ulong desc = 0;
    desc |= cast(ulong)(limit & 0xFFFF);
    desc |= cast(ulong)(base & 0xFFFF) << 16;
    desc |= cast(ulong)((base >> 16) & 0xFF) << 32;
    desc |= cast(ulong)access << 40;
    desc |= cast(ulong)(((limit >> 16) & 0x0F) | (flags & 0xF0)) << 48;
    desc |= cast(ulong)((base >> 24) & 0xFF) << 56;
    return desc;
}

private void
set_tss_desc(ushort slot, ulong base, uint limit)
{
    ulong low = 0;
    ulong high = 0;

    low |= cast(ulong)(limit & 0xFFFF);
    low |= cast(ulong)(base & 0xFFFF) << 16;
    low |= cast(ulong)((base >> 16) & 0xFF) << 32;
    low |= cast(ulong)0x89 << 40; /* present, type = available 64-bit TSS */
    low |= cast(ulong)((limit >> 16) & 0x0F) << 48;
    low |= cast(ulong)((base >> 24) & 0xFF) << 56;

    high |= cast(ulong)((base >> 32) & 0xFFFF_FFFF);

    gdt_table[slot] = low;
    gdt_table[slot + 1] = high;
}

/* ------------------------------------------------------------------ */
/* External assembly helper                                             */
/* ------------------------------------------------------------------ */

extern(C) void gdt_flush(GDTR*);
extern(C) void tss_flush(ushort);

/* ------------------------------------------------------------------ */
/* Public init                                                          */
/* ------------------------------------------------------------------ */

/**
 * Populate the GDT and install it.
 *
 * Access byte legend (non-system segments):
 *   Bit 7   P   = Present
 *   Bits 6:5 DPL = Descriptor Privilege Level (0 = ring 0)
 *   Bit 4   S   = 1 (code/data, not a system descriptor)
 *   Bit 3   E   = 1 → code segment, 0 → data segment
 *   Bit 2   DC  = Direction/Conforming (0 for both here)
 *   Bit 1   RW  = Readable (code) / Writable (data)
 *   Bit 0   A   = Accessed (set by CPU; we write 0)
 *
 * Flags nibble (upper 4 bits of the flags_limit byte):
 *   Bit 7   G   = Granularity (1 = 4 KiB pages, limit × 4096)
 *   Bit 6   DB  = Default size (0 for 64-bit code; 1 for 32-bit data)
 *   Bit 5   L   = 64-bit code segment flag (must be 1 for 64-bit code)
 *   Bit 4   AVL = Available (ignored by CPU)
 */
void
gdt_init() {
    gdt_table[0] = make_entry(0, 0, 0x00, 0x00);

    /* 0x08 — kernel 64-bit code
     *   access = 0x9A  P=1, DPL=0, S=1, E=1, DC=0, RW=1, A=0
     *   flags  = 0xA0  G=1, DB=0, L=1, AVL=0  (upper nibble 0xA) */
    gdt_table[1] = make_entry(0, 0xFFFFF, 0x9A, 0xA0);

    /* 0x10 — kernel data
     *   access = 0x92  P=1, DPL=0, S=1, E=0, D=0, W=1, A=0
     *   flags  = 0xC0  G=1, DB=1, L=0, AVL=0 */
    gdt_table[2] = make_entry(0, 0xFFFFF, 0x92, 0xC0);

    /* 0x18 — reserved (SYSRET compat32 slot, unused — must be null) */
    gdt_table[3] = 0;

    /* 0x20 — user data  (DPL=3) */
    gdt_table[4] = make_entry(0, 0xFFFFF, 0xF2, 0xC0);

    /* 0x28 — user 64-bit code  (DPL=3: access bits 6:5 = 11) */
    gdt_table[5] = make_entry(0, 0xFFFFF, 0xFA, 0xA0);

    tss = TSS64.init;
    tss.rsp0 = cast(ulong)privilege_stack.ptr + privilege_stack.length;
    tss.ist1 = cast(ulong)double_fault_stack.ptr + double_fault_stack.length;
    tss.iopb_offset = TSS64.sizeof;

    set_tss_desc(6, cast(ulong)&tss, TSS64.sizeof - 1);

    gdt_ptr.limit = cast(ushort)(ulong.sizeof * NUM_ENTRIES - 1);
    gdt_ptr.base  = cast(ulong) gdt_table.ptr;

    gdt_flush( &gdt_ptr );
    tss_flush( TSS_CPU0 );
}
