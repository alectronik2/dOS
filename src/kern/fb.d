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
}
