module hal.bootboot;

const BOOTBOOT_MMIO  = 0xfffffffff8000000; /* memory mapped IO virtual address */
const BOOTBOOT_FB    = 0xfffffffffc000000;  /* frame buffer virtual address */
const BOOTBOOT_INFO  = 0xffffffffffe00000;  /* bootboot struct virtual address */
const BOOTBOOT_ENV   = 0xffffffffffe01000;  /* environment string virtual address */
const BOOTBOOT_CORE  = 0xffffffffffe02000;  /* core loadable segment start */

/* minimum protocol level:
 *  hardcoded kernel name, static kernel memory addresses */
const PROTOCOL_MINIMAL = 0;
/* static protocol level:
 *  kernel name parsed from environment, static kernel memory addresses */
const PROTOCOL_STATIC  = 1;
/* dynamic protocol level:
 *  kernel name parsed, kernel memory addresses from ELF or PE symbols */
const PROTOCOL_DYNAMIC = 2;

const PROTOCOL_BIGENDIAN = 0x80;

const LOADER_BIOS = 0 << 2;
const LOADER_UEFI = 1 << 2;
const LOADER_RPI  = 2 << 2;
const LOADER_COREBOOT = 3 << 2;

const FB_ARGB = 0;
const FB_RGBA = 1;
const FB_ABGR = 2;
const FB_BGRA = 3;

enum MMapType : u8 {
    Used = 0,
    Free = 1,
    Acpi = 2,
    Mmio = 3,
}

struct MMapEnt {
align(1):
    u64 base;
    u64 _size;

    @property u64 size() {
        return _size & 0x7FFF_FFFF_FFFF_FFF0;
    }

    @property MMapType type() {
        return cast(MMapType)( _size & 0xF );
    }
    
    @property bool is_available() {
        bool ret = (type == MMapType.Free);
        return ret;
    }
}

struct BootBoot {
    u8[4] magic; /* "BBOT" */
    u32   size;
    u8 protocol;
    u8 fb_type;
    u16 numcores;
    u16 bspid;
    i16 timezone;
    u8[8] datetime;
    u64 initrd_ptr;
    u64 initrd_size;
    u64 fb_ptr;
    u32 fb_size;
    u32 fb_width;
    u32 fb_height;
    u32 fb_scanline;

    union {
        struct x86_64 {
            u64 acpi_ptr;
            u64 smbi_ptr;
            u64 efi_ptr;
            u64 mp_pre;
            u64[4] unused;
        }

        struct AArch64 {
            u64 acpi_ptr;
            u64 mmio_ptr;
            u64 efi_ptr;
            u64[5] unused;
        }
    }
}

extern(C) __gshared BootBoot bootboot;