module lib.print;

import core.stdc.stdarg;
import lib.runtime, hal.serial;
import hal.cpu, hal.bootboot;

__gshared {
    extern(C) u8 framebuffer;
    extern(C) extern u8 _binary_font_psf_start;

    u32 *fb;
    u32 pitch;
    u32 width;
    u32 height;
    u8  bpp;

    u32 cols;
    u32 rows;
    u32 cx;
    u32 cy;

    u32 fg = COL_WHITE, bg = COL_BLACK;
}

struct psf2_t {
align(1):
    u32 magic;
    u32 _version;
    u32 headersize;
    u32 flags;
    u32 numglyph;
    u32 bytesperglyph;
    u32 height;
    u32 width;
    u8 glyphs;
}

const FONT_W = 8;
const FONT_H = 16;

const COL_BLACK = 0x0;
const COL_BLUE = 0xAA;
const COL_GREEN = 0x0000AA00;
const COL_CYAN = 0x0000AAAA;
const COL_RED = 0x00AA0000;
const COL_MAGENTA = 0x00AA00AA;
const COL_BROWN = 0x00AA5500;
const COL_LIGHT_GREY = 0x00AAAAAA;
const COL_DARK_GREY = 0x00555555;
const COL_BRIGHT_BLUE = 0x005555FF;
const COL_BRIGHT_GREEN = 0x0055FF55;
const COL_BRIGHT_CYAN = 0x0055FFFF;
const COL_BRIGHT_RED = 0x00FF5555;
const COL_BRIGHT_MAGENTA = 0x00FF55FF;
const COL_BRIGHT_YELLOW = 0x00FFFF55;
const COL_WHITE = 0x00FFFFFF;

private @property psf2_t* activeFont() {
    return cast(psf2_t*) &_binary_font_psf_start;
}

private @property u32 cellWidth() {
    return activeFont.width + 1;
}

private @property u32 cellHeight() {
    return activeFont.height + 1;
}

void
color( const(char)* name ) {
    bool
    eq( string color ) {
        return !strncmp(cast(char *)name, color.ptr, color.length );
    }

    if( eq("BLUE") )    fg = COL_BLUE;
    if( eq("GREEN") )   fg = COL_GREEN;
    if( eq("CYAN") )    fg = COL_CYAN;
    if( eq("RED") )     fg = COL_RED;
    if( eq("MAGENTA") ) fg = COL_MAGENTA;
    if( eq("BROWN") )   fg = COL_BROWN;
    if( eq("/") )       fg = COL_LIGHT_GREY;
    if( eq("DGREY") )   fg = COL_DARK_GREY;
    if( eq("B_BLUE") )  fg = COL_BRIGHT_BLUE;
    if( eq("B_GREEN") ) fg = COL_BRIGHT_GREEN;
    if( eq("B_CYAN") )  fg = COL_BRIGHT_CYAN;
    if( eq("B_RED") )   fg = COL_BRIGHT_RED;
    if( eq("B_MAGENTA") ) fg = COL_BRIGHT_MAGENTA;
    if( eq("WHITE") ) fg = COL_WHITE;
    if( eq("B_BLACK") ) fg = COL_BLACK;
}

void
clear() {
    auto p = cast(ubyte*) fb;
    size_t total = cast(size_t) pitch * height;
    memset(p, 0, total);
    cx = 0;
    cy = 0;
}

void
scroll() {
    auto p = cast(ubyte*) fb;
    auto totalBytes = cast(size_t) pitch * height;
    auto rowBytes = cast(size_t) pitch * cellHeight;

    if (rowBytes >= totalBytes) {
        memset(p, 0, totalBytes);
        cy = 0;
        return;
    }

    /* Move everything up by one text row. */
    memmove(p, p + rowBytes, totalBytes - rowBytes);

    /* Clear the last text row. */
    memset(p + (totalBytes - rowBytes), 0, rowBytes);

    cy = rows - 1;
}

void
put_glyph( uint col, uint row, ubyte ch ) {
    auto font = cast(psf2_t*) &_binary_font_psf_start;
    auto f    = cast(ubyte*) font + font.headersize;
    auto bytesperline = (font.width + 7) / 8;
    auto fb = cast(u32*) &framebuffer;
    auto offs = col * (font.width + 1) * 4 + row * (font.height + 1) * bootboot.fb_scanline;
    auto idx = (ch > 0 && cast(u32)(ch) < font.numglyph) ? ch * font.bytesperglyph : 0;

    foreach( y; 0 .. font.height ) {
        auto line = offs;
        auto mask = 1 << (font.width - 1);

        foreach( x; 0 .. font.width ) {
            if( (f[idx] & mask) == 0)
                fb[line / 4] = bg;  /* background colour */
            else
                fb[line / 4] = fg;  /* foreground colour */

            mask >>= 1;
            line += 4;
        }

        idx += bytesperline;
        offs += bootboot.fb_scanline;
    }
}

void
putc( char c ) {
    if (c == '\n') {
        cx = 0;
        cy++;
    } else if (c == '\b') {
        if (cx > 0)
        {
            cx--;
            /* Erase the character cell. */
            put_glyph(cx, cy, ' ');
        }
    } else {
        put_glyph(cx, cy, cast(ubyte) c);
        cx++;
        if (cx >= cols) { cx = 0; cy++; }
    }

    if (cy >= rows)
        scroll();
}


void _puts(const(char)* s) {
    if (!s) s = "(null)";
    while (*s) putc(*s++);
}

void _puthex(ulong v, int width, char pad, bool upper) {
    const(char)* digits = upper ? "0123456789ABCDEF"
                                : "0123456789abcdef";
    char[16] buf = void;
    int n = 0;
    do { buf[n++] = digits[v & 0xF]; v >>= 4; } while (v);
    while (n < width) buf[n++] = pad;
    for (int i = n - 1; i >= 0; i--) putc(buf[i]);
}

void _putuint(ulong v, int width = 0, char pad = ' ') {
    char[20] buf = void;
    int n = 0;
    do { buf[n++] = cast(char)('0' + v % 10); v /= 10; } while (v);
    for (int k = n; k < width; k++) putc(pad);
    for (int i = n - 1; i >= 0; i--) putc(buf[i]);
}

void _putbin(ulong v, int width, char pad) {
    char[64] buf = void;
    int n = 0;
    do { buf[n++] = cast(char)('0' + (v & 1)); v >>= 1; } while (v);
    while (n < width) buf[n++] = pad;
    for (int i = n - 1; i >= 0; i--) putc(buf[i]);
}

void _putint(long v, int width = 0, char pad = ' ') {
    char[20] buf = void;
    int n = 0;
    bool neg = v < 0;
    ulong u = neg ? cast(ulong)(-v) : cast(ulong) v;
    do { buf[n++] = cast(char)('0' + u % 10); u /= 10; } while (u);
    int total = n + (neg ? 1 : 0);
    if (pad == '0') {
        if (neg) putc('-');
        for (int k = total; k < width; k++) putc('0');
    } else {
        for (int k = total; k < width; k++) putc(' ');
        if (neg) putc('-');
    }
    for (int i = n - 1; i >= 0; i--) putc(buf[i]);
}


void
fb_init( u32 fb_pitch, u32 fb_width, u32 fb_height, u8 fb_bpp ) {
    u32 bytes_per_pixel = fb_bpp / 8;

    fb = cast(uint*)&framebuffer;
    pitch = fb_pitch ? fb_pitch : fb_width * bytes_per_pixel;
    width = fb_width;
    height = fb_height;
    bpp = fb_bpp;

    cols = width / cellWidth;
    rows = height / cellHeight;
}

void 
_to_cstr(char* dst, const(char)* src, int len, int dstSize)
{
    int n = (len < dstSize - 1) ? len : dstSize - 1;
    for (int i = 0; i < n; i++) dst[i] = src[i];
    dst[n] = '\0';
}

void
vkprintf( const(char)* fmt, va_list ap ) {
    va_list ap_copy;
    for (const(char)* p = fmt; *p; p++) {
        if (*p != '{') { putc(*p); continue; }

        // Locate the matching '}'
        const(char)* s = p + 1;
        const(char)* e = s;
        while (*e && *e != '}') e++;
        if (!*e) break;         // unterminated '{' – abort
        p = e;                  // outer loop's p++ skips past '}'

        int len = cast(int)(e - s);
        if (len == 0) continue; // bare {} – ignore

        // ── Parse optional zero-pad flag and field width ──────────────────────
        char pad   = ' ';
        int  width = 0;
        int  i     = 0;

        if (s[i] == '0') { pad = '0'; i++; }   // leading '0' = zero-pad flag

        while (i < len && s[i] >= '0' && s[i] <= '9')
            width = width * 10 + (s[i++] - '0');

        const(char)* spec    = s + i;
        int          speclen = len - i;

        // ── Single-character format specifiers ────────────────────────────────
        if (speclen == 1) switch (spec[0])
        {
            case 'c': putc    (cast(char) va_arg!int(ap));            continue;
            case 's': _puts   (va_arg!(const(char)*)(ap));           continue;
            case 'd': _putint (va_arg!long(ap), width, pad);         continue;
            case 'i': _putint (va_arg!long(ap), width, pad);         continue;
            case 'u': _putuint(va_arg!ulong(ap), width, pad);        continue;
            case 'b': _putbin (va_arg!ulong(ap), width, pad);        continue;
            case 'x': _puthex (va_arg!ulong(ap), width, pad, false); continue;
            case 'X': _puthex (va_arg!ulong(ap), width, pad, true);  continue;
            case 'p': _puthex (va_arg!ulong(ap), width, pad, true);  continue;
            default:  break;
        }

        // ── Anything else is a colour name (e.g. "red", "green", "/") ────────
        char[32] name = void;
        _to_cstr(name.ptr, s, len, name.length);
        color(name.ptr);
    }
}

extern(C) void
kprintf( const(char)* fmt, ... ) {
    va_list ap;
    va_start(ap, fmt);
    vkprintf( fmt, ap );
    va_end(ap);
}

extern(C) void
kpanic( const(char)* fmt, ... ) {
    va_list ap;
    va_start(ap, fmt);
    vkprintf( "KERNEL PANIC:\n", ap );
    vkprintf( fmt, ap );
    va_end(ap);

    hang();
}
