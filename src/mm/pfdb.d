module mm.pfdb;

import lib.klog, lib.bitfields, lib.runtime;
import hal.limine, main, hal.cpu;

const PAGE_SIZE         = 4096;
const PAGE_SHIFT        = 12;

const KERNEL_SPACE_BASE = 0xFFFF_FFFF_0000_0000;   // kernel address space starts here
const KERNEL_VIRTUAL_ADDR = 0xFFFF_FFFF_8000_0000; // kernel virtual address

const PADDR_4K_MASK     = 0x000F_FFFF_FFFF_F000;
const PADDR_2M_MASK     = 0x000F_FFFF_FFE0_0000;
const PADDR_1G_MASK     = 0x000F_FFFF_C000_0000;

const HUGE_PAGE_2M      = 0x80;
const GIB               = 1024UL * 1024 * 1024;

struct Memory {
    ulong       max_phys_addr;     // highest physical mem address
    ulong       free_mem;          // available memory

    ulong       num_frames;        // page frame count
    PageFrame*  pfdb, pfdb_end;    // page frame database
    ulong       pfdb_bytes;        // size of the page frame database

    ulong       hhdm_offset;       // higher half direct mapping

    MemmapEntry **entries;         // limine memory maps
    ulong       entry_count;       //   <- count

    PageFrame*  free_list;
    ulong       free_pages;

    ulong       kernel_pml4;
}

__gshared Memory m;

enum FrameType : ubyte {
    Other       = 0,
    Reserved    = 1,
    Kernel      = 2,
    PFDB        = 3,
    Malloc      = 4,
    HugeMalloc  = 5,
    HANDLETAB   = 6,
    Free        = 7,
}

struct PageFrame {
align(1):
    FrameType tag;
    union {
        ulong size;
        PageFrame* next;
    }
}

/* Page flags */
enum Page {
    Present  = (1UL << 0),
    Writable = (1UL << 1),
    User     = (1UL << 2),
    Global   = (1UL << 8),
    NoExec   = (1UL << 63),
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

ulong pages_num( ulong v ) => (v + PAGE_SIZE - 1) >> PAGE_SHIFT;

void
free_pageframe( ulong pfn ) {
    auto pf = &m.pfdb[pfn];
    pf.tag = FrameType.Free;
    pf.next = m.free_list;
    m.free_list = pf;
    m.free_pages++;
}

ulong
alloc_pageframe( FrameType type = FrameType.Other ) {
    if( !m.free_list ) kpanic!"Out of memory";
    auto pf = m.free_list;
    m.free_list = pf.next;
    pf.tag = type;

    m.free_pages--;
    return pf - m.pfdb;
}

/* converts a physical into virtual memory address */
ulong
p2v( ulong paddr ) {
    return m.hhdm_offset + paddr;
}

/* Translate virtual address to physical address */
ulong
v2p( ulong p, ulong vaddr ) {
    auto idx = PageFrameIndexer(vaddr);

    /* Shortcut for identity mapping */
    if( vaddr > m.hhdm_offset && vaddr < m.hhdm_offset + m.max_phys_addr )
        return vaddr - m.hhdm_offset;

    auto pml4 = cast(Pte*)p2v(p);
    if( !pml4[idx.l4].present ) {
        klog!"PML4 entry not present\n";
        return -1;
    }

    auto pdpt = cast(Pte*)p2v(pml4[idx.l4].paddr);
    if( !pdpt[idx.l3].present ) {
        klog!"PDPT entry not present\n";
        return -1;
    }

    /* 1G huge page */
    if( pdpt[idx.l3].ps ) {
        klog!"PDPT huge page detected\n";
        return (pdpt[idx.l3].paddr & PADDR_1G_MASK) + (vaddr & (GIB - 1));
    }

    auto pd = cast(Pte*)p2v(pdpt[idx.l3].paddr);
    if( !pd[idx.l2].present ) {
        klog!"PD entry not present\n";
        return -1;
    }

    /* 2M huge page */
    if( pd[idx.l2].ps ) {
        klog!"PD huge page detected\n";
        return (pd[idx.l2].paddr & PADDR_2M_MASK) + (vaddr & ((1UL << 21) - 1));
    }

    auto pt = cast(Pte*)p2v(pd[idx.l2].paddr);
    if( pt[idx.l1].present == 0 )
        return -1;

    return pt[idx.l1].paddr;
}

/* Translate virtual address to page frame */
PageFrame*
v2pf( ulong vaddr ) {
    auto paddr = v2p( m.kernel_pml4, vaddr );
    assert( paddr != -1 );

    auto idx = paddr >> PAGE_SHIFT;
    assert( idx < m.num_frames );

    return &m.pfdb[idx];
}

ulong
alloc_page() {
    return alloc_pageframe() << PAGE_SHIFT;
}

bool
map_page( ulong pml4_ptr, ulong vaddr, ulong paddr, ulong flags = Page.Present | Page.Writable | Page.Global ) {
    auto idx = PageFrameIndexer(vaddr);
    auto user = flags & 0x4;

    auto pml4 = cast(Pte*)p2v(pml4_ptr);
    if( !pml4[idx.l4].present ) {
        auto new_pdpt = alloc_page();
        memset( cast(void*)p2v(new_pdpt), 0, PAGE_SIZE );
        pml4[idx.l4] .raw = new_pdpt | flags | Page.Present;
    } else if( user ) {
        pml4[idx.l4].raw |= 0x4;
    }

    auto pdpt = cast(Pte*)p2v(pml4[idx.l4].paddr);
    if( !pdpt[idx.l3].present) {
        auto new_pd = alloc_page();
        memset( cast(void*)p2v(new_pd), 0, PAGE_SIZE );
        pdpt[idx.l3].raw = new_pd | flags | Page.Present;
    } else if( user ) {
        pdpt[idx.l3].raw |= 0x4;
    }
    if( pdpt[idx.l3].ps ) {
        klog!"PDPT hugepage detected, cannot map page\n";
        return false;
    }

    auto pd = cast(Pte*)p2v(pdpt[idx.l3].paddr);
    if( !pd[idx.l2].present ) {
        auto new_pt = alloc_page();
        memset( cast(void*)p2v(new_pt), 0, PAGE_SIZE );
        pd[idx.l2].raw = new_pt | flags | Page.Present;
    } else if( user ) {
        pd[idx.l2].raw |= 0x4;
    }

    if( pd[idx.l2].ps ) {
        klog!"PD hugepage detected, cannot map page\n";
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

    invlpg( vaddr );
}

//
// allocates memory during early bringup, returns physical address
//
ulong
boot_alloc_phys_range( ulong size, ulong alignment = PAGE_SIZE ) {
    size = roundup( size, PAGE_SIZE );

    foreach( i; 0 .. m.entry_count ) {
        auto entry = m.entries[i];
        auto end = entry.base + entry.length;
        if( entry.type == MemoryMapType.Usable ) {
            if( (entry.length + alignment) < size ) continue;

            auto base = roundup( entry.base, alignment );
            entry.base += size;

            m.free_mem -= size;
            return base;
        }
    }
    assert( false, "boot_alloc_phys_range: out of memory" );
}

void
pfdb_mark_page( ulong pfn, FrameType tag ) {
    assert( pfn < m.num_frames );
    m.pfdb[pfn].tag = tag;
}

void
pfdb_mark_range( ulong start, ulong end, FrameType tag ) {
    auto start_pf = start >> PAGE_SHIFT;
    auto end_pf = end >> PAGE_SHIFT;

    assert( start_pf < end_pf );
    assert( end_pf <= m.num_frames );

    for( ulong i = start_pf; i < end_pf; i++ ) {
        m.pfdb[i].tag = tag;
    }
}

void
pfdb_mark_range_free( ulong start, ulong end ) {
    auto start_pf = start >> PAGE_SHIFT;
    auto end_pf = end >> PAGE_SHIFT;

    assert( start_pf < end_pf );
    assert( end_pf <= m.num_frames );

    for( ulong i = start_pf; i < end_pf; i++ ) {
        m.pfdb[i].tag = FrameType.Free;
        m.pfdb[i].next = m.free_list;
        m.free_list = &m.pfdb[i];

        m.free_pages++;
    }

    ktrace!" -> Marked PFN <Red>%i</>-<Cyan>%i</> free\n"(start_pf, end_pf);
}

void
pfdb_init( ulong count, MemmapEntry** entries, ulong hhdm_offset ) {
    // enable global pages
    cpu_enable_pge();

    m.kernel_pml4 = read_cr3() & PADDR_4K_MASK;

    m.entry_count = count;
    m.entries     = entries;
    m.hhdm_offset = hhdm_offset;

    klog!"Memory layout: Direct mapping @ 0x%x\n"(hhdm_offset);

    foreach( i; 0 .. m.entry_count ) {
        auto entry = m.entries[i];
        klog!" -> base <Cyan>0x%x</> length <Blue>%i</> KiB type <Cyan>%i</>\n"(entry.base, entry.length / 1024, entry.type);

        if( entry.type == hal.limine.MemoryMapType.Usable ) {
            if( m.max_phys_addr < entry.base + entry.length )
                m.max_phys_addr = entry.base + entry.length;
            m.free_mem += entry.length;
        }

        auto e = entries[i];
    }

    m.num_frames = m.max_phys_addr >> PAGE_SHIFT;
    m.pfdb_bytes = m.num_frames * PageFrame.sizeof;

    m.pfdb = cast(PageFrame*)p2v( boot_alloc_phys_range(m.pfdb_bytes) );
    m.pfdb_end = cast(PageFrame*)(cast(ulong)m.pfdb + m.pfdb_bytes);
    klog!"<Green>Available:</> %i MB, <Red>PageFrameDatabase:</> %i KB @ 0x%x - <Green>Max phys addr:</> 0x%x\n"(m.free_mem / 1024 / 1024, m.pfdb_bytes / 1024, m.pfdb, m.max_phys_addr);

    memset( m.pfdb, 0, m.pfdb_bytes );

    foreach( i; 0 .. m.entry_count ) {
        auto entry = m.entries[i];
        if( entry.type != hal.limine.MemoryMapType.Usable ) continue;

        auto rbase = entry.base;
        auto rend  = rbase + entry.length;

        if( rbase >= m.max_phys_addr ) continue; // entirely above mapped range
        if( rend > m.max_phys_addr ) rend = m.max_phys_addr;

        pfdb_mark_range_free( rbase, rend );
    }

    test_paging();
}

void
test_paging() {
    auto pf1 = alloc_page();
    auto v   = p2v( pf1 );
    klog!"Allocated pageframe %i - mapped at 0x%x\n"(pf1, v);

    auto p = cast(ulong*)v;
    *p = 0xCAFEBABE;
    klog!" - value: 0x%x\n"(*p);

    map_page( m.kernel_pml4, 0x40_0000, pf1 );
    auto p2 = cast(ulong*)0x40_0000;
    *p2 = 0xDEADBABE;
    klog!" - mapping, value: 0x%x\n"(*p);

    import lib.runtime;

    auto pml4 = alloc_page();
    ulong ret;
    auto pml4_va = p2v( pml4 );
    memcpy( cast(void*)(pml4_va+2048), cast(void*)p2v(m.kernel_pml4 + 2048), 2048 );
    m.kernel_pml4 = pml4;
    write_cr3( pml4 );
    klog!"<bg:red>CR3 updated</>\n";
}
