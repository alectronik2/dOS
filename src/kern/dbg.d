module kern.dbg;

import lib.print;

// Frame record as laid out by the ABI
struct StackFrame {
    StackFrame* prev;
    ulong       retAddr;
}

// Reasonable limit to avoid runaway walks on corrupt stacks
enum MAX_FRAMES = 32;

// Boundaries — set these from your linker script symbols
extern(C) extern __gshared ubyte __kernel_start;
extern(C) extern __gshared ubyte __kernel_end;

/// Returns true if `addr` looks like a plausible kernel text pointer.
private bool isKernelText(ulong addr) {
    immutable ulong lo = cast(ulong)&__kernel_start;
    immutable ulong hi = cast(ulong)&__kernel_end;
    return addr >= lo && addr < hi;
}

/// Returns true if `ptr` is a canonical, aligned kernel stack address.
/// Adjust the stack VA range to match your kernel's virtual map.
private bool isValidFramePtr(StackFrame* ptr) {
    immutable ulong p = cast(ulong)ptr;
    // Must be 8-byte aligned, non-null, and within your kernel stack VA window.
    // Example: kernel stacks at 0xFFFF_8000_0000_0000 .. 0xFFFF_FFFF_FFFF_FFFF
    return (p != 0) && (p & 7) == 0 && (p >= 0xFFFF_800000000000UL);
}

/// Walk the call stack from `startFrame` (pass current RBP).
void printStackTrace(StackFrame* startFrame) {
    kprintf("--- stack backtrace ---");
    StackFrame* frame = startFrame;

    for (int depth = 0; depth < MAX_FRAMES; ++depth) {
        if (!isValidFramePtr(frame))
            break;

        ulong retAddr = frame.retAddr;
        if (retAddr == 0)
            break;

        // Symbol lookup: if you have a System.map table, call it here.
        // Otherwise just print raw addresses.
        const(char)* sym = lookupSymbol(retAddr); // can return null
        if (sym !is null)
            kprintf("  #%d  0x{016x}  <{s}>\n", depth, retAddr, sym);
        else
            kprintf("  #%d  0x{016x}\n", depth, retAddr);

        frame = frame.prev;
    }

    kprintf("--- end backtrace ---");
}

const(char)*
lookupSymbol( ulong addr ) {
    return null;
}

/// Capture current RBP and walk immediately.
void backtraceHere() {
    StackFrame* rbp;
    asm @nogc nothrow {
        mov rbp, RBP;
    }
    printStackTrace(rbp);
}