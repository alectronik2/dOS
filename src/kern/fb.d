module kern.fb;

static import hal.limine;
import lib.klog, lib.runtime, hal.cpu;

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

const DEFAULT_FG = COL_WHITE;
const DEFAULT_BG = COL_BLACK;

struct Framebuffer {
    u32 *fb;
    u32 pitch;
    u32 width;
    u32 height;
    u16 bpp;

    u32 cols;
    u32 rows;
    u32 cx;
    u32 cy;

    u32 fg = COL_WHITE, bg = COL_BLACK;

    @property psf2_t*
    activeFont() {
        return cast(psf2_t*) &_binary_various_font_psf_start;
    }

    @property u32 cellWidth() {
        return activeFont.width + 1;
    }

    @property u32 cellHeight() {
        return activeFont.height + 1;
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
    reset_colors() {
        fg = DEFAULT_FG;
        bg = DEFAULT_BG;
    }

    private void applyAnsiSgrCode(int code) {
        if (code == 0) {
            reset_colors();
            return;
        }

        if (code >= 30 && code <= 37) {
            fg = ansiFgColor(code);
            return;
        }

        if (code >= 40 && code <= 47) {
            bg = ansiBgColor(code);
            return;
        }

        if (code >= 90 && code <= 97) {
            fg = ansiFgColor(code);
            return;
        }

        if (code >= 100 && code <= 107) {
            bg = ansiBgColor(code);
            return;
        }
    }

    void
    _puts(const(char)* s) {
        if (!s) s = "(null)";
        while (*s) putc(*s++);
    }

    void
    _puthex(ulong v, int width, char pad, bool upper) {
        const(char)* digits = upper ? "0123456789ABCDEF"
                                    : "0123456789abcdef";
        char[16] buf = void;
        int n = 0;
        do { buf[n++] = digits[v & 0xF]; v >>= 4; } while (v);
        while (n < width) buf[n++] = pad;
        for (int i = n - 1; i >= 0; i--) putc(buf[i]);
    }

    void
    _putuint(ulong v, int width = 0, char pad = ' ') {
        char[20] buf = void;
        int n = 0;
        do { buf[n++] = cast(char)('0' + v % 10); v /= 10; } while (v);
        for (int k = n; k < width; k++) putc(pad);
        for (int i = n - 1; i >= 0; i--) putc(buf[i]);
    }

    void
    _putbin(ulong v, int width, char pad) {
        char[64] buf = void;
        int n = 0;
        do { buf[n++] = cast(char)('0' + (v & 1)); v >>= 1; } while (v);
        while (n < width) buf[n++] = pad;
        for (int i = n - 1; i >= 0; i--) putc(buf[i]);
    }

    void
    _putint(long v, int width = 0, char pad = ' ') {
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

    void
    put_glyph( uint col, uint row, ubyte ch ) {
        auto font = cast(psf2_t*) &_binary_various_font_psf_start;
        auto f    = cast(ubyte*) font + font.headersize;
        auto bytesperline = (font.width + 7) / 8;
        auto offs = col * (font.width + 1) * 4 + row * (font.height + 1) * pitch;
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
            offs += pitch;
        }
    }

    void write_ansi(const(char)* s, uint len) {
        if (!fb_ready || s is null || len == 0)
            return;

        uint i = 0;
        while (i < len) {
            char c = s[i++];

            if (c != '\x1B') {
                putc(c);
                continue;
            }

            if (i >= len || s[i] != '[') {
                putc(c);
                continue;
            }
            i++;

            bool sawCode = false;
            while (i < len) {
                auto code = parseAnsiCode(s, len, i);
                if (code != uint.max) {
                    applyAnsiSgrCode(cast(int)code);
                    sawCode = true;
                } else if (!sawCode) {
                    applyAnsiSgrCode(0);
                }

                if (i >= len)
                    break;

                char term = s[i++];
                if (term == 'm')
                    break;
                if (term != ';')
                    break;
            }
        }
    }
}

private uint
parseAnsiCode(const(char)* s, uint len, ref uint idx) {
    int value = 0;
    bool haveDigits = false;

    while (idx < len) {
        char c = s[idx];
        if (c < '0' || c > '9')
            break;
        haveDigits = true;
        value = value * 10 + (c - '0');
        idx++;
    }

    if (!haveDigits)
        return uint.max;

    return cast(uint)value;
}

private u32 ansiFgColor(int code) {
    final switch (code) {
        case 30: return COL_BLACK;
        case 31: return COL_RED;
        case 32: return COL_GREEN;
        case 33: return COL_BROWN;
        case 34: return COL_BLUE;
        case 35: return COL_MAGENTA;
        case 36: return COL_CYAN;
        case 37: return COL_LIGHT_GREY;
        case 90: return COL_DARK_GREY;
        case 91: return COL_BRIGHT_RED;
        case 92: return COL_BRIGHT_GREEN;
        case 93: return COL_BRIGHT_YELLOW;
        case 94: return COL_BRIGHT_BLUE;
        case 95: return COL_BRIGHT_MAGENTA;
        case 96: return COL_BRIGHT_CYAN;
        case 97: return COL_WHITE;
    }
}

private u32 ansiBgColor(int code) {
    final switch (code) {
        case 40: return COL_BLACK;
        case 41: return COL_RED;
        case 42: return COL_GREEN;
        case 43: return COL_BROWN;
        case 44: return COL_BLUE;
        case 45: return COL_MAGENTA;
        case 46: return COL_CYAN;
        case 47: return COL_LIGHT_GREY;
        case 100: return COL_DARK_GREY;
        case 101: return COL_BRIGHT_RED;
        case 102: return COL_BRIGHT_GREEN;
        case 103: return COL_BRIGHT_YELLOW;
        case 104: return COL_BRIGHT_BLUE;
        case 105: return COL_BRIGHT_MAGENTA;
        case 106: return COL_BRIGHT_CYAN;
        case 107: return COL_WHITE;
    }
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

__gshared {
    extern(C) extern u8 _binary_various_font_psf_start;

    bool fb_ready = false;
    Framebuffer fb;
}

void
fb_init( hal.limine.Framebuffer *f ) {
    fb.fb = cast(u32*)f.address;
    fb.width = cast(u32)f.width;
    fb.height = cast(u32)f.height;
    fb.pitch = cast(u32)f.pitch;
    fb.bpp = cast(u16)f.bpp;

    klog!"Framebuffer: %ix%ix%i @ 0x%x - pitch %i\n"(fb.width, fb.height, fb.bpp, fb.fb, fb.pitch);

    fb.cols = fb.width / fb.cellWidth;
    fb.rows = fb.height / fb.cellHeight;

    fb_ready = true;
}
