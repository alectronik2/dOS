module mm.pfdb;

import lib.print, lib.bitfields, lib.runtime;
import hal.bootboot, hal.cpu;

const IDENTITY_MAP_BASE = 0xFFFF_8000_0000_0000;
const KERNEL_OFFSET     = 0xffff_ffff_ffe0_2000;
const KERNEL_SPACE_BASE = 0xFFFF_FFFF_8000_0000;

const PADDR_4K_MASK     = 0x000F_FFFF_FFFF_F000;
const PADDR_2M_MASK     = 0x000F_FFFF_FFE0_0000;
const PADDR_1G_MASK     = 0x000F_FFFF_C000_0000;
const HUGE_PAGE_2M      = 0x80;
const GIB               = 1024UL * 1024 * 1024;
enum MAX_EARLY_HHDM_PDS = 16;

struct MemRegion {
    paddr base;
    u64   length;
    u32   type;

    @property bool is_available() {
        return type == 1;
    }
}

enum PageFrameType : ubyte {
    Other       = 0,
    Reserved    = 1,
    Kernel      = 2,
    PFDB        = 3,
    Malloc      = 4,
    HugeMalloc  = 5,
    Free        = 6,
}

enum Page {
    Present  = (1UL << 0),
    Writable = (1UL << 1),
    User     = (1UL << 2),
    Global   = (1UL << 8),
    NoExec   = (1UL << 63),
}


struct PageFrame {
align(1):
    PageFrameType tag;
    union {
        ulong size;
        PageFrame* next;
    }
}

struct Pte {
    ulong raw;
    
    mixin(BitStructMixin!(ulong,
            "present",  ubyte,  1,
            "rw",       ubyte,  1,
            "user",     ubyte,  1,
            "pwt",      ubyte,  1,
            "pcd",      ubyte,  1,
            "accessed", ubyte,  1,
            "dirty",    ubyte,  1,
            "ps",       ubyte,  1,
            "global",   ubyte,  1,
            "avail",    ubyte,  3,
        ));

    @property ulong paddr() {
        return raw & PADDR_4K_MASK;
    }

    @property ulong pfn() {
        return raw >> PAGE_SHIFT;   
    }
}

enum MAX_MEM_REGIONS = 64;

__gshared {
    extern(C) u8 __kernel_end; /* Defined in linker script, end of kernel image */

    MemRegion[MAX_MEM_REGIONS] mem_regions;
    ulong                      mem_region_count;
    u64                        avail_memory;
    u64                        max_phys_addr;

    PageFrame*                 pfdb, pfdb_end;
    PageFrame*                 free_list;
    ulong                      free_pages;
    ulong free_start;

    ulong simple_heap_start;
    ulong simple_heap_end;

    ulong kernel_pml4;
    
    bool early = true; // Whether we're still in early boot before paging is fully set up

    align(4096) Pte[512]                         early_hhdm_pdpt;
    align(4096) Pte[512][MAX_EARLY_HHDM_PDS]     early_hhdm_pds;
}

ulong pages_num( ulong v ) => (v + PAGE_SIZE - 1) >> PAGE_SHIFT;

ulong
boot_alloc_phys_page() {
    auto cursor = roundup( free_start, PAGE_SIZE );

    foreach( i; 0 .. mem_region_count ) {
        if( !mem_regions[i].is_available ) continue;

        auto rbase = roundup( mem_regions[i].base, PAGE_SIZE );
        auto rend = mem_regions[i].base + mem_regions[i].length;

        if( cursor < rbase )
            cursor = rbase;
        if( cursor + PAGE_SIZE > rend )
            continue;

        free_start = cursor + PAGE_SIZE;
        return cursor;
    }

    assert( 0, "boot_alloc_phys_page: out of memory" );
    return 0;
}

ulong
alloc_pt_page() {
    if( early && free_list is null )
        return boot_alloc_phys_page();

    auto pfn = alloc_pageframe();
    assert( pfn != 0 );
    return pfn << PAGE_SHIFT;
}

/* Translate physical address to virtual address */
ulong
p2v( ulong paddr ) {
    if( early )
        return paddr;
    return paddr + IDENTITY_MAP_BASE;
}

/* Translate virtual address to page frame */
PageFrame*
v2pf( ulong vaddr ) {
    //kprintf( "{RED}v2pf: vaddr=0x{x}{/}\n", vaddr );

    auto paddr = v2p( kernel_pml4, vaddr );
    auto idx = paddr >> PAGE_SHIFT;

    assert( paddr != -1 );
    //kprintf( "===={CYAN}v2pf: vaddr=0x{x}, paddr=0x{x}, idx={i}{/}\n", vaddr, paddr, idx );
    assert( idx < (pfdb_end - pfdb) );
    
    return &pfdb[idx];
}

/* Translate virtual address to physical address */
ulong
v2p( ulong p, ulong vaddr ) {
    auto idx = PageFrameIndexer(vaddr);

    /* Shortcut for identity mapping */
    if( vaddr > IDENTITY_MAP_BASE && vaddr < IDENTITY_MAP_BASE + max_phys_addr ) 
        return vaddr - IDENTITY_MAP_BASE;

    auto pml4 = cast(Pte*)p2v(p);
    if( !pml4[idx.l4].present ) {
        kprintf( "PML4 entry not present\n" );
        return -1;
    }
    
    auto pdpt = cast(Pte*)p2v(pml4[idx.l4].paddr);
    if( !pdpt[idx.l3].present ) {
        kprintf( "PDPT entry not present\n" );
        return -1;
    }

    /* 1G huge page */
    if( pdpt[idx.l3].ps ) {
        kprintf( "PDPT huge page detected\n" );
        return (pdpt[idx.l3].paddr & PADDR_1G_MASK) + (vaddr & ~PADDR_1G_MASK);
    }

    auto pd = cast(Pte*)p2v(pdpt[idx.l3].paddr);
    if( !pd[idx.l2].present ) {
        kprintf( "PD entry not present\n" );
        return -1;
    }
    
    /* 2M huge page */
    if( pd[idx.l2].ps ) {
        kprintf( "PD huge page detected\n" );
        return (pd[idx.l2].paddr & PADDR_2M_MASK) + (vaddr & ~PADDR_2M_MASK);
    }
    
    auto pt = cast(Pte*)p2v(pd[idx.l2].paddr);
    if( pt[idx.l1].present == 0 )
        return -1;

    return pt[idx.l1].paddr;
}

/* Indexer for calculating page frame indices */
struct PageFrameIndexer {
    ulong addr;

    this( ulong addr ) {
        this.addr = addr;
    }

    @property ulong l4() {
        return (addr >> 39) & 0x1FF;
    }

    @property ulong l3() {
        return (addr >> 30) & 0x1FF;
    }

    @property ulong l2() {
        return (addr >> 21) & 0x1FF;
    }

    @property ulong l1() {
        return (addr >> 12) & 0x1FF;
    }
}

bool
map_page( ulong pml4_ptr, ulong vaddr, ulong paddr, ulong flags = Page.Present | Page.Writable | Page.Global ) {
    auto idx = PageFrameIndexer(vaddr);
    auto user = flags & 0x4;

    auto pml4 = cast(Pte*)p2v(pml4_ptr);
    if( !pml4[idx.l4].present ) {
        auto new_pdpt = alloc_pt_page();
        memset( cast(void*)p2v(new_pdpt), 0, PAGE_SIZE );
        pml4[idx.l4] .raw = new_pdpt | flags | Page.Present;
    } else if( user ) {
        pml4[idx.l4].raw |= 0x4;
    }

    auto pdpt = cast(Pte*)p2v(pml4[idx.l4].paddr);
    if( !pdpt[idx.l3].present) {
        auto new_pd = alloc_pt_page();
        memset( cast(void*)p2v(new_pd), 0, PAGE_SIZE );
        pdpt[idx.l3].raw = new_pd | flags | Page.Present;   
    } else if( user ) {
        pdpt[idx.l3].raw |= 0x4;
    }
    if( pdpt[idx.l3].ps ) {
        kprintf( "PDPT hugepage detected, cannot map page\n" );
        return false;
    }

    auto pd = cast(Pte*)p2v(pdpt[idx.l3].paddr);
    if( !pd[idx.l2].present ) {
        auto new_pt = alloc_pt_page();
        memset( cast(void*)p2v(new_pt), 0, PAGE_SIZE );
        pd[idx.l2].raw = new_pt | flags | Page.Present;    
    } else if( user ) {
        pd[idx.l2].raw |= 0x4;
    }

    if( pd[idx.l2].ps ) {
        kprintf( "PD hugepage detected, cannot map page\n" );
        return false;
    }

    auto pt = cast(Pte*)p2v(pd[idx.l2].paddr);
    pt[idx.l1].raw = paddr | flags | Page.Present;

    return true;
}

void
unmap_page( ulong pml4_ptr, ulong vaddr ) {
    auto idx = PageFrameIndexer(vaddr);

    auto pml4 = cast(Pte*)p2v(pml4_ptr);
    if( !pml4[idx.l4].present ) return;
    auto pdpt = cast(Pte*)p2v(pml4[idx.l4].paddr);
    if( !pdpt[idx.l3].present ) return;
    if( pdpt[idx.l3].ps ) {
        pdpt[idx.l3].raw = 0;
        return;
    }
    auto pd = cast(Pte*)p2v(pdpt[idx.l3].paddr);
    if( !pd[idx.l2].present ) return;
    if( pd[idx.l2].ps ) {
        pd[idx.l2].raw = 0;
        return; 
    }
    auto pt = cast(Pte*)p2v(pd[idx.l2].paddr);
    if( !pt[idx.l1].present ) return;   
    pt[idx.l1].raw = 0;

    tlb_shootdown( vaddr );
}

void
unmap_range( ulong pml4_ptr, ulong vaddr_start, ulong vaddr_end ) {
    for( ulong addr = vaddr_start; addr < vaddr_end; addr += PAGE_SIZE ) {
        unmap_page( pml4_ptr, addr );
    }
}

void
map_range( ulong pml4_ptr, ulong vaddr_start, ulong paddr_start, ulong size, ulong flags ) {
    assert( (vaddr_start & (PAGE_SIZE - 1)) == 0 );
    assert( (paddr_start & (PAGE_SIZE - 1)) == 0 );
    assert( (size & (PAGE_SIZE - 1)) == 0 );

    for( ulong offset = 0; offset < size; offset += PAGE_SIZE ) {
        auto vaddr = vaddr_start + offset;
        auto paddr = paddr_start + offset;

        if( !map_page( pml4_ptr, vaddr, paddr, flags ) ) {
            kprintf( "Failed to map page: vaddr=0x{x}, paddr=0x{x}\n", vaddr, paddr );
        }
    }
}

void
bootstrap_map_phys_window( ulong pml4_ptr, ulong phys_size, ulong flags ) {
    auto idx = PageFrameIndexer( IDENTITY_MAP_BASE );
    auto num_pds = (phys_size + GIB - 1) / GIB;

    assert( num_pds <= MAX_EARLY_HHDM_PDS );

    memset( &early_hhdm_pdpt[0], 0, early_hhdm_pdpt.sizeof );
    memset( &early_hhdm_pds[0][0], 0, early_hhdm_pds.sizeof );

    foreach( i; 0 .. num_pds ) {
        auto pd = &early_hhdm_pds[i][0];
        auto pd_paddr = v2p( pml4_ptr, cast(ulong)pd );
        assert( pd_paddr != -1 );

        early_hhdm_pdpt[i].raw = pd_paddr | flags | 1;

        foreach( j; 0 .. 512 ) {
            auto paddr = i * GIB + (j << 21);
            if( paddr >= phys_size )
                break;

            pd[j].raw = paddr | flags | HUGE_PAGE_2M | 1;
        }
    }

    auto pdpt_paddr = v2p( pml4_ptr, cast(ulong)&early_hhdm_pdpt[0] );
    assert( pdpt_paddr != -1 );

    auto pml4 = cast(Pte*)p2v( pml4_ptr );
    pml4[idx.l4].raw = pdpt_paddr | flags | 1;
}

ulong
pfn_from_vpaddr( paddr addr ) {
    assert( addr < IDENTITY_MAP_BASE );
    return (addr - IDENTITY_MAP_BASE) >> PAGE_SHIFT;
}

void *
simple_heap_alloc( ulong size ) {
    if( simple_heap_start + size > simple_heap_end )
        return null; // OOM
    auto ptr = cast(void*)simple_heap_start;
    simple_heap_start += size;

    return ptr;
}

void
pfdb_mark_page( ulong pfn, PageFrameType tag ) {
    assert( pfn < (pfdb_end - pfdb) );
    pfdb[pfn].tag = tag;
}

void
pfdb_mark_range( ulong start, ulong end, PageFrameType tag ) {
    auto start_pf = start >> PAGE_SHIFT;
    auto end_pf = end >> PAGE_SHIFT;
    
    assert( start_pf < end_pf );
    assert( end_pf <= cast(ulong)(pfdb_end - pfdb) );

    for( ulong i = start_pf; i < end_pf; i++ ) {
        pfdb[i].tag = tag;
    }
}

void
pfdb_mark_range_free( ulong start, ulong end ) {
    auto start_pf = start >> PAGE_SHIFT;
    auto end_pf = end >> PAGE_SHIFT;

    assert( start_pf < end_pf );
    assert( end_pf <= cast(ulong)(pfdb_end - pfdb) );

    for( ulong i = start_pf; i < end_pf; i++ ) {
        pfdb[i].tag = PageFrameType.Free;
        pfdb[i].next = free_list;
        free_list = &pfdb[i];

        free_pages++;
    }

    kprintf( "Marked PFN {i}..{i} free\n", start_pf, end_pf );
}

void
tlb_shootdown( ulong va ) {
    asm {
        invlpg [va];
    }

    // TODO: lapicSendShootdownIPI
}

void
pfdb_init() {
    __gshared static ulong am = 0;
    ulong pfdb_paddr;
    ulong mapped_phys_size;
    ulong mmap_count;

    cpu_enable_pge();

    kprintf( "BootBoot size: {x}, {i} regions\n", bootboot.size, (bootboot.size - BootBoot.sizeof) / MMapEnt.sizeof );
    
    kernel_pml4 = read_cr3();

    auto mmap = cast(MMapEnt*)(cast(ulong)&bootboot + BootBoot.sizeof);
    mmap_count = (bootboot.size - BootBoot.sizeof) / MMapEnt.sizeof;
    assert( mmap_count <= MAX_MEM_REGIONS, "pfdb_init: memory map exceeds mem_regions capacity" );
    mem_region_count = mmap_count;
    foreach( i; 0 .. mem_region_count ) {
        mem_regions[i] = MemRegion( mmap[i].base, mmap[i].size, mmap[i].type );
        //kprintf( "{GREEN}Region {RED}{i}{WHITE}: base={WHITE}0x{x}, size={i}M, type={i}\n", i, mem_regions[i].base, mem_regions[i].length / (1024 * 1024), mem_regions[i].type );

        if( mmap[i].is_available ) {
            am += mmap[i].size;
            if( mmap[i].base + mmap[i].size > max_phys_addr )
                max_phys_addr = mmap[i].base + mmap[i].size;
        }
    }

    kprintf( "Available memory: {i} MiB\n", am / (1024 * 1024) );

    auto num_frames = max_phys_addr >> PAGE_SHIFT;
    auto pfdb_bytes = num_frames * PageFrame.sizeof;
    mapped_phys_size = roundup( max_phys_addr, PAGE_SIZE );

    pfdb_paddr = roundup( cast(ulong)0x200000, PAGE_SIZE );
    free_start = roundup( pfdb_paddr + pfdb_bytes, PAGE_SIZE );

    bootstrap_map_phys_window( kernel_pml4, mapped_phys_size, 0x3 );
    early = false;

    pfdb = cast(PageFrame*)p2v( pfdb_paddr );
    pfdb_end = cast(PageFrame*)(cast(ulong)pfdb + pfdb_bytes);
    memset( pfdb, 0, pfdb_bytes );

    foreach( i; 0 .. mem_region_count ) {
        if( !mem_regions[i].is_available ) continue;

        auto rbase = mem_regions[i].base;
        auto rend = rbase + mem_regions[i].length;

        if( rbase >= max_phys_addr ) continue;  // entirely above mapped range
        if( rend > max_phys_addr ) rend = max_phys_addr;
        if( rend <= free_start ) continue;      // entirely below PFDB/heap
        if( rbase < free_start ) rbase = free_start;

        pfdb_mark_range_free( rbase, rend );  
    }

    pfdb_mark_range( 0x100000, 0x200000, PageFrameType.Kernel );
    pfdb_mark_range( 0x0, 0x100000, PageFrameType.Reserved ); // Mark first 1 MiB as reserved (for real mode, BIOS, etc.)
    pfdb_mark_range( pfdb_paddr, free_start, PageFrameType.PFDB );

    kprintf( "PFDB initialized: {i} frames, {i} ({i} MiB) free\n", num_frames, free_pages, free_pages * PAGE_SIZE / (1024 * 1024) );

    unmap_range( kernel_pml4, 0x0, mapped_phys_size );


}

void
free_pageframe( ulong pfn ) {
    auto pf = &pfdb[pfn];
    pf.tag = PageFrameType.Free;
    pf.next = free_list;
    free_list = pf;
    free_pages++;
}

ulong
alloc_pageframe() {
    if( !free_list )
        return 0; // OOM
    auto pf = free_list;
    free_list = pf.next;
    pf.tag = PageFrameType.Other; // Mark as allocated with unknown purpose
    
    free_pages--;
    return pf - pfdb;
}
