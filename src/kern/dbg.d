module kern.dbg;

import lib.klog;

// Frame record as laid out by the ABI
struct StackFrame {
    StackFrame* prev;
    ulong       retAddr;
}

// Reasonable limit to avoid runaway walks on corrupt stacks
enum MAX_FRAMES = 32;
enum MAX_SYMBOLS = 8192;

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
    klog!"--- stack backtrace ---\n";
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
            klogf!"  #%d  0x%016x  <%s>\n"(depth, retAddr, sym);
        else
            klogf!"  #%d  0x%016x\n"(depth, retAddr);

        frame = frame.prev;
    }

    klog!"--- end backtrace ---\n";
}

/// Capture current RBP and walk immediately.
void backtraceHere() {
    StackFrame* rbp;
    asm @nogc nothrow {
        mov rbp, RBP;
    }
    printStackTrace(rbp);
}

struct Symbol {
    ulong addr;
    const(char)* name;
}

__gshared Symbol[MAX_SYMBOLS] g_symtab;
__gshared size_t       g_symCount;

extern(C) extern __gshared ubyte _binary_build_System_map_start;
extern(C) extern __gshared ubyte _binary_build_System_map_end;

bool isHexDigit(char c) {
    return (c >= '0' && c <= '9') ||
           (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}

bool isSpace(char c) {
    return c == ' ' || c == '\t';
}

ulong parseHex(const(char)* p, size_t len) {
    ulong v = 0;
    foreach (i; 0 .. len) {
        char c = p[i];
        uint nibble =
            (c >= '0' && c <= '9') ? c - '0' :
            (c >= 'a' && c <= 'f') ? c - 'a' + 10 :
                                     c - 'A' + 10;
        v = (v << 4) | nibble;
    }
    return v;
}

bool isHexToken(const(char)* p, size_t len) {
    if (len == 0) return false;
    foreach (i; 0 .. len) {
        if (!isHexDigit(p[i])) return false;
    }
    return true;
}

void skipSpaces(const(char)* p, size_t lineLen, ref size_t pos) {
    while (pos < lineLen && isSpace(p[pos])) ++pos;
}

size_t tokenLen(const(char)* p, size_t lineLen, size_t pos) {
    size_t end = pos;
    while (end < lineLen && !isSpace(p[end])) ++end;
    return end - pos;
}

// Returns slice length of the current line, sets *next to start of next line.
size_t nextLine(const(char)* buf, size_t remaining, const(char)** next) {
    size_t i = 0;
    while (i < remaining && buf[i] != '\n') ++i;
    *next = buf + i + (i < remaining ? 1 : 0);
    return i;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
public:

/// Call once during early boot, after the memory map is up.
void
symmap_init() {
    const(char)* p   = cast(const(char)*) &_binary_build_System_map_start;
    const(char)* end = cast(const(char)*) &_binary_build_System_map_end;
    size_t count = 0;

    while (p < end && count < MAX_SYMBOLS) {
        const(char)* lineStart = p;
        size_t remaining = end - p;
        const(char)* nextP;
        size_t lineLen = nextLine(p, remaining, &nextP);

        // Supported line formats:
        //   <addr> <type> <name>
        //   <addr> <size> <type> <name>   (nm --print-size)
        size_t pos = 0;
        skipSpaces(p, lineLen, pos);

        size_t addrStart = pos;
        size_t addrLen = tokenLen(p, lineLen, pos);
        if (addrLen > 0 && addrLen <= 16 && isHexToken(p + addrStart, addrLen)) {
            ulong addr = parseHex(p + addrStart, addrLen);
            pos += addrLen;
            skipSpaces(p, lineLen, pos);

            size_t fieldStart = pos;
            size_t fieldLen = tokenLen(p, lineLen, pos);

            // nm --print-size inserts a hexadecimal size before the type.
            if (fieldLen > 1 && fieldLen <= 16 && isHexToken(p + fieldStart, fieldLen)) {
                pos += fieldLen;
                skipSpaces(p, lineLen, pos);
                fieldStart = pos;
                fieldLen = tokenLen(p, lineLen, pos);
            }

            if (fieldLen == 1) {
                char typeChar = p[fieldStart];
                bool keep = typeChar == 'T' || typeChar == 't' ||
                            typeChar == 'D' || typeChar == 'd' ||
                            typeChar == 'R' || typeChar == 'r' ||
                            typeChar == 'B' || typeChar == 'b';

                pos = fieldStart + fieldLen;
                skipSpaces(p, lineLen, pos);

                if (keep && pos < lineLen) {
                    char* name = cast(char*)(p + pos);
                    size_t nameLen = lineLen - pos;
                    name[nameLen] = '\0';

                    g_symtab[count].addr = addr;
                    g_symtab[count].name = name;
                    ++count;
                }
            }
        }

        p = nextP;
    }

    g_symCount = count;
    // Already sorted by nm --numeric-sort, so no sort step needed.
}

/// Binary search: find the nearest symbol at or below `addr`.
const(char)*
lookupSymbol(ulong addr) {
    if (g_symCount == 0) return null;

    size_t lo = 0, hi = g_symCount - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo + 1) / 2;
        if (g_symtab[mid].addr <= addr)
            lo = mid;
        else
            hi = mid - 1;
    }

    // Discard if we're more than 64 KiB past the symbol start
    if (addr - g_symtab[lo].addr > 0x10000) return null;
    return g_symtab[lo].name;
}
