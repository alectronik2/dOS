module lib.klog;

import lib.lock, hal.serial;

public enum LogLevel : ubyte {
    Trace  = 0,
    Debug  = 1,
    Info   = 2,
    Warn   = 3,
    Error  = 4,
    Panic  = 5,
    Silent = 6,
}

public:
// ─── in-memory ring buffer ────────────────────────────────────────────────────

version (LogNoRing) {} else {

enum uint LOG_RING_SIZE = 65536;   // power of 2

__gshared char[LOG_RING_SIZE] g_ring;
__gshared uint g_ringHead = 0;
__gshared uint g_ringUsed = 0;

void ringWrite(const(char)* s, uint len) {
    for (uint i = 0; i < len; i++) {
        g_ring[g_ringHead & (LOG_RING_SIZE - 1)] = s[i];
        g_ringHead++;
        if (g_ringUsed < LOG_RING_SIZE) g_ringUsed++;
    }
}

public:

/**
 * Copy up to `bufLen` bytes of the ring buffer into `buf` (oldest-first).
 * ANSI escapes are included; strip them if you need plain text.
 * Returns the number of bytes written.
 */
uint logDumpRing(char* buf, uint bufLen) {
    if (!buf || bufLen == 0) return 0;
    uint avail = g_ringUsed < bufLen ? g_ringUsed : bufLen;
    uint start = (g_ringHead - g_ringUsed) & (LOG_RING_SIZE - 1);
    for (uint i = 0; i < avail; i++)
        buf[i] = g_ring[(start + i) & (LOG_RING_SIZE - 1)];
    return avail;
}

private:
} // !LogNoRing

// ─── compile-time colour tag resolution ──────────────────────────────────────
//
// resolveTag(name) is a pure compile-time function that maps a tag name to
// its ANSI SGR escape string.  Under -version=LogNoColour it always returns
// "" so the tag is completely erased with zero code-size impact.

private pure string resolveTag(string name) {
    version (LogNoColour) { return ""; }

    // ── reset ──────────────────────────────────────────────────────────────
    if (name == "/"      ) return "\x1B[0m";
    if (name == "reset"  ) return "\x1B[0m";

    // ── text attributes ────────────────────────────────────────────────────
    if (name == "bold"   ) return "\x1B[1m";
    if (name == "dim"    ) return "\x1B[2m";
    if (name == "ul"     ) return "\x1B[4m";
    if (name == "blink"  ) return "\x1B[5m";
    if (name == "rev"    ) return "\x1B[7m";

    // ── normal foreground (SGR 30-37) ──────────────────────────────────────
    if (name == "black"  ) return "\x1B[30m";
    if (name == "red"    ) return "\x1B[31m";
    if (name == "green"  ) return "\x1B[32m";
    if (name == "yellow" ) return "\x1B[33m";
    if (name == "blue"   ) return "\x1B[34m";
    if (name == "magenta") return "\x1B[35m";
    if (name == "cyan"   ) return "\x1B[36m";
    if (name == "white"  ) return "\x1B[37m";

    // ── bright foreground (SGR 90-97) — capitalise first letter ───────────
    if (name == "Black"  ) return "\x1B[90m";
    if (name == "Red"    ) return "\x1B[91m";
    if (name == "Green"  ) return "\x1B[92m";
    if (name == "Yellow" ) return "\x1B[93m";
    if (name == "Blue"   ) return "\x1B[94m";
    if (name == "Magenta") return "\x1B[95m";
    if (name == "Cyan"   ) return "\x1B[96m";
    if (name == "White"  ) return "\x1B[97m";

    // ── background (SGR 40-47) — prefix "bg:" ─────────────────────────────
    if (name == "bg:black"  ) return "\x1B[40m";
    if (name == "bg:red"    ) return "\x1B[41m";
    if (name == "bg:green"  ) return "\x1B[42m";
    if (name == "bg:yellow" ) return "\x1B[43m";
    if (name == "bg:blue"   ) return "\x1B[44m";
    if (name == "bg:magenta") return "\x1B[45m";
    if (name == "bg:cyan"   ) return "\x1B[46m";
    if (name == "bg:white"  ) return "\x1B[47m";

    return "";   // unknown tag → silently swallow
}

// Compile-time: scan forward from `pos` looking for '>'.
// Returns the index of '>' or fmt.length if not found.
private pure size_t findTagClose(string fmt, size_t pos) {
    for (size_t i = pos; i < fmt.length; i++)
        if (fmt[i] == '>') return i;
    return fmt.length;
}

// ─── level prefix strings ─────────────────────────────────────────────────────

version (LogNoColour) {
    private enum string[6] LEVEL_PREFIX = [
        "[TRC] ", "[DBG] ", "[INF] ", "[WRN] ", "[ERR] ", "[!!!] "
    ];
} else {
    private enum string[6] LEVEL_PREFIX = [
        "\x1B[2;36m[TRC]\x1B[0m ",   // dim cyan
        "\x1B[0;34m[DBG]\x1B[0m ",   // blue
        "\x1B[0;32m[INF]\x1B[0m ",   // green
        "\x1B[0;33m[WRN]\x1B[0m ",   // yellow
        "\x1B[0;31m[ERR]\x1B[0m ",   // red
        "\x1B[1;31m[!!!]\x1B[0m ",   // bold red
    ];
}

// ─── global state ─────────────────────────────────────────────────────────────

version (LogDebugBuild)
    __gshared LogLevel g_logLevel = LogLevel.Trace;
else
    __gshared LogLevel g_logLevel = LogLevel.Info;

__gshared bool     g_logReady = false;
__gshared Spinlock g_logLock;

// ─── line buffer ─────────────────────────────────────────────────────────────

enum uint LOG_LINE_MAX = 1024;

private struct LineBuf {
    char[LOG_LINE_MAX] data;
    uint               len;

    void put(char c) {
        if (len < LOG_LINE_MAX - 1) data[len++] = c;
    }
    void puts(const(char)* s, uint n) {
        for (uint i = 0; i < n && len < LOG_LINE_MAX - 1; i++)
            data[len++] = s[i];
    }
    // string overload (used for compile-time ANSI strings)
    void puts(string s) {
        puts(s.ptr, cast(uint)s.length);
    }
    const(char)* ptr() const { return data.ptr; }
}

// ─── integer formatters ───────────────────────────────────────────────────────

private void fmtUlong(ref LineBuf b, ulong v, uint base,
                      bool upper, uint minWidth, char padChar) 
{
    char[64] tmp;
    uint pos = 0;
    if (v == 0) {
        tmp[pos++] = '0';
    } else {
        while (v) {
            uint d = cast(uint)(v % base);
            char c = (d < 10) ? cast(char)('0' + d)
                              : (upper ? cast(char)('A' + d - 10)
                                       : cast(char)('a' + d - 10));
            tmp[pos++] = c;
            v /= base;
        }
    }
    if (minWidth > pos)
        for (uint i = 0; i < minWidth - pos; i++) b.put(padChar);
    for (uint i = pos; i > 0; ) b.put(tmp[--i]);
}

private void fmtLong(ref LineBuf b, long v, uint minWidth, char padChar)
    
{
    if (v < 0) { b.put('-'); fmtUlong(b, cast(ulong)(-v), 10, false, 0, ' '); }
    else        fmtUlong(b, cast(ulong)v, 10, false, minWidth, padChar);
}

// ─── compile-time format + colour-tag parser ─────────────────────────────────
//
// emitFmt!(fmt, pos, Args...)(b, args)
//
// Recursively walks `fmt` from `pos` at compile time.
//
//   '<'       → read until '>', call resolveTag(), emit the ANSI string.
//               Does NOT consume an argument.
//   '%spec'   → format args[0] according to spec, recurse with Args[1..$]
//   '%%'      → emit literal '%'
//   anything  → emit the character literally

private template emitFmt(string fmt, size_t pos, Args...)
{
    // ── No args remaining: emit literals and colour tags only ─────────────
    static if (Args.length == 0)
    {
        void emitFmt(ref LineBuf b) 
        {
            static if (pos < fmt.length)
            {
                // Colour tag
                static if (fmt[pos] == '<')
                {
                    enum size_t close = findTagClose(fmt, pos + 1);
                    enum string tag   = fmt[pos + 1 .. close];
                    enum string ansi  = resolveTag(tag);
                    static if (ansi.length > 0) b.puts(ansi);
                    .emitFmt!(fmt, close + 1)(b);
                }
                // %%
                else static if (fmt[pos] == '%' && pos + 1 < fmt.length
                                && fmt[pos + 1] == '%')
                {
                    b.put('%');
                    .emitFmt!(fmt, pos + 2)(b);
                }
                // Literal
                else
                {
                    b.put(fmt[pos]);
                    .emitFmt!(fmt, pos + 1)(b);
                }
            }
        }
    }
    // ── Args remaining ────────────────────────────────────────────────────
    else
    {
        void emitFmt(ref LineBuf b, Args args) 
        {
            static if (pos >= fmt.length)
            {
                // fmt exhausted — discard remaining args silently
            }

            // ── Colour tag (no arg consumed) ──────────────────────────────
            else static if (fmt[pos] == '<')
            {
                enum size_t close = findTagClose(fmt, pos + 1);
                enum string tag   = fmt[pos + 1 .. close];
                enum string ansi  = resolveTag(tag);
                static if (ansi.length > 0) b.puts(ansi);
                .emitFmt!(fmt, close + 1, Args)(b, args);
            }

            // ── '%' specifier ─────────────────────────────────────────────
            else static if (fmt[pos] == '%')
            {
                enum size_t p1 = pos + 1;

                static if (p1 >= fmt.length)
                {
                    b.put('%');   // bare % at end of string
                }
                // %%
                else static if (fmt[p1] == '%')
                {
                    b.put('%');
                    .emitFmt!(fmt, p1 + 1, Args)(b, args);
                }
                else
                {
                    // Optional zero-pad flag
                    enum bool   zeroPad  = (fmt[p1] == '0');
                    enum size_t p2       = zeroPad ? p1 + 1 : p1;

                    // Optional decimal width
                    enum size_t wEnd     = parseDigits!(fmt, p2);
                    enum uint   fmtWidth = parseUint(fmt[p2 .. wEnd]);

                    // Optional 'l' length modifier
                    enum bool   longMod  = (wEnd < fmt.length
                                            && fmt[wEnd] == 'l');
                    enum size_t specPos  = longMod ? wEnd + 1 : wEnd;

                    static if (specPos >= fmt.length)
                    {
                        b.put('%');
                    }
                    else
                    {
                        enum char spec = fmt[specPos];
                        alias     A0   = typeof(args[0]);

                        static if (spec == 'd' || spec == 'i')
                            fmtLong(b, cast(long)args[0], fmtWidth,
                                    zeroPad ? '0' : ' ');
                        else static if (spec == 'u')
                            fmtUlong(b, cast(ulong)args[0], 10, false,
                                     fmtWidth, zeroPad ? '0' : ' ');
                        else static if (spec == 'x')
                            fmtUlong(b, cast(ulong)args[0], 16, false,
                                     fmtWidth, zeroPad ? '0' : ' ');
                        else static if (spec == 'X')
                            fmtUlong(b, cast(ulong)args[0], 16, true,
                                     fmtWidth, zeroPad ? '0' : ' ');
                        else static if (spec == 'o')
                            fmtUlong(b, cast(ulong)args[0], 8, false,
                                     fmtWidth, zeroPad ? '0' : ' ');
                        else static if (spec == 'b')
                            fmtUlong(b, cast(ulong)args[0], 2, false,
                                     fmtWidth, zeroPad ? '0' : ' ');
                        else static if (spec == 'c')
                            b.put(cast(char)args[0]);
                        else static if (spec == 's')
                        {
                            static if (is(A0 == string) ||
                                       is(A0 : const(char)[]))
                            {
                                b.puts(args[0].ptr, cast(uint)args[0].length);
                            }
                            else
                            {
                                auto sp = cast(const(char)*)args[0];
                                if (sp is null) b.puts("(null)");
                                else { uint n = 0; while (sp[n]) n++;
                                       b.puts(sp, n); }
                            }
                        }
                        else static if (spec == 'p')
                        {
                            b.puts("0x");
                            fmtUlong(b, cast(ulong)args[0], 16, false, 16, '0');
                        }
                        else
                        {
                            b.put('%');
                            b.put(spec);
                        }

                        .emitFmt!(fmt, specPos + 1, Args[1..$])(b, args[1..$]);
                    }
                }
            }

            // ── Literal character ─────────────────────────────────────────
            else
            {
                b.put(fmt[pos]);
                .emitFmt!(fmt, pos + 1, Args)(b, args);
            }
        }
    }
}

// ─── compile-time helpers ─────────────────────────────────────────────────────

private template parseDigits(string s, size_t pos) {
    static if (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
        enum size_t parseDigits = parseDigits!(s, pos + 1);
    else
        enum size_t parseDigits = pos;
}

private uint parseUint(string s) pure {
    uint v = 0;
    foreach (c; s) if (c >= '0' && c <= '9') v = v * 10 + (c - '0');
    return v;
}

// ─── sink dispatch ────────────────────────────────────────────────────────────

private void sinkWrite(const(char)* s, uint len) {
    serial_write(s, len);
    //version (LogNoVga)  {} else vgaPuts(s, len);
    version (LogNoRing) {} else ringWrite(s, len);
}

// ─── public API ───────────────────────────────────────────────────────────────

public:

/**
 * Initialise the logging subsystem.
 * Must be called before any klog!() use.
 */
void logInit(LogLevel minLevel = LogLevel.Trace) {
    //uartInit();
    g_logLevel = minLevel;
    g_logReady = true;
}

/// Change the runtime log-level filter.
void logSetLevel(LogLevel l) { g_logLevel = l; }

// ─── core emit (file+line are template params, not runtime args) ─────────────
//
// Separating file/line as template parameters rather than default function
// parameters ensures they never appear in Args and can never be forwarded
// to emitFmt by mistake.

template klogImpl(string fmt, string file, int line, bool suppress_level=false)
{
    void klogImpl(Args...)(LogLevel level, Args args) 
    {
        if (level < g_logLevel) return;

        LineBuf b;
        if( !suppress_level ) {
        //version (LogCallSite) {
            // Trim path to leaf filename at compile time
            enum string leaf = ctLeaf(file);
            b.puts(leaf.ptr, cast(uint)leaf.length);
            b.put(':');
            fmtUlong(b, cast(ulong)line, 10, false, 0, ' ');
            b.put(' ');
        //}

            emitFmt!(fmt, 0, Args)(b, args);

            b.puts(LEVEL_PREFIX[level < 6 ? level : 5]);
        }

        g_logLock.lock();
        sinkWrite(b.ptr(), b.len);
        g_logLock.unlock();
    }
}

// Compile-time: return the substring of `s` after the last '/' or '\'.
private string ctLeaf(string s) pure {
    size_t i = s.length;
    while (i > 0 && s[i-1] != '/' && s[i-1] != '\\') i--;
    return s[i .. $];
}

/**
 * Primary log template.  Format string and colour tags are fully resolved
 * at compile time; only the runtime argument values are evaluated.
 *
 *   klog!"[pci] <green>OK</> found %04x:%04x\n"(vendor, device);
 *   klog!"[mmu] <Red>FAULT</> at <yellow>%016lx</>\n"(addr);
 *   klog!"<bold><cyan>SMP</></> AP %u online\n"(apicId);
 *   klog!"<bg:red><White> PANIC </></> %s\n"(msg);
 *   klog!"irq <dim>%u</> → gsi <Yellow>%u</>\n"(irq, gsi);
 */
template klog(string fmt, string file = __FILE__, int line = __LINE__) {
    void klog(Args...)(Args args) {
        klogImpl!(fmt, file, line)(LogLevel.Info, args);
    }
}

// doesn't print file and line prefixes
template klogf(string fmt, string file = __FILE__, int line = __LINE__) {
    void klogf(Args...)(Args args) {
        klogImpl!(fmt, file, line)(LogLevel.Info, args, true);
    }
}

/**
 * Severity-explicit variant:
 *
 *   klogT!"<yellow>%s</> latency %u µs\n"(LogLevel.Warn, name, lat);
 */
template klogT(string fmt, string file = __FILE__, int line = __LINE__) {
    void klogT(Args...)(LogLevel level, Args args) {
        klogImpl!(fmt, file, line)(level, args);
    }
}

// ─── convenience wrappers ─────────────────────────────────────────────────────

/// Log at Trace level.
template ktrace(string fmt, string file = __FILE__, int line = __LINE__) {
    void ktrace(Args...)(Args args) {
        klogImpl!(fmt, file, line)(LogLevel.Trace, args);
    }
}

/// Log at Debug level.
template kdebug(string fmt, string file = __FILE__, int line = __LINE__) {
    void kdebug(Args...)(Args args) {
        klogImpl!(fmt, file, line)(LogLevel.Debug, args);
    }
}

/// Log at Info level (alias for klog).
alias kinfo = klog;

/// Log at Warn level.
template kwarn(string fmt, string file = __FILE__, int line = __LINE__) {
    void kwarn(Args...)(Args args) {
        klogImpl!(fmt, file, line)(LogLevel.Warn, args);
    }
}

/// Log at Error level.
template kerror(string fmt, string file = __FILE__, int line = __LINE__) {
    void kerror(Args...)(Args args) {
        klogImpl!(fmt, file, line)(LogLevel.Error, args);
    }
}

/**
 * Panic — log at Panic level (bypasses g_logLevel), then halt.
 */
template kpanic(string fmt, string file = __FILE__, int line = __LINE__) {
    void kpanic(Args...)(Args args) {
        LogLevel saved = g_logLevel;
        g_logLevel = LogLevel.Trace;
        klogImpl!(fmt, file, line)(LogLevel.Panic, args);
        g_logLevel = saved;
        asm { "cli"; }
        while (true) asm { "hlt"; }
    }
}

// ─── assert ──────────────────────────────────────────────────────────────────

void kassert(bool cond, const(char)* msg,
             string file = __FILE__, int line = __LINE__)
    
{
    if (!cond) {
        LineBuf b;
        b.puts(LEVEL_PREFIX[LogLevel.Panic]);
        b.puts("ASSERT FAILED: ");
        if (msg) { uint n = 0; while (msg[n]) n++; b.puts(msg, n); }
        b.puts("  at ");
        b.puts(file.ptr, cast(uint)file.length);
        b.put(':');
        fmtUlong(b, cast(ulong)line, 10, false, 0, ' ');
        b.put('\n');
        sinkWrite(b.ptr(), b.len);
        asm { "cli"; }
        while (true) asm { "hlt"; }
    }
}
