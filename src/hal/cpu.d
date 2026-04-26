module hal.cpu;

import lib.klog, kern.thread;

void
enable_interrupts() {
    asm {
        naked;
        sti;
        ret;
    }
}

void
disable_interrupts() {
    asm {
        naked;
        cli;
        ret;
    }
}

ulong
save_interrupts() {
    ulong flags;

    asm {
        pushfq;
        pop flags;
        cli;
    }

    return flags;
}

void
restore_interrupts(ulong flags) {
    asm {
        push flags;
        popfq;
    }
}

void
hang() {
    while( true )
        asm { hlt; }
}

u64
read_cr2() {
    u64 cr2;
    asm {
        mov RAX, CR2;
        mov cr2, RAX;
    }
    return cr2;
}

u64
read_cr3() {
    u64 cr3;
    asm {
        mov RAX, CR3;
        mov cr3, RAX;
    }
    return cr3;
}

void
write_cr3( u64 val ) {
    asm {
        mov RAX, val;
        mov CR3, RAX;
    }
}

void
wrmsr( u32 msr, u64 value ) {
    auto lo = cast(u32)(value & 0xFFFF_FFFF);
    auto hi = cast(u32)(value >> 32);
    asm {
        mov ECX, msr;
        mov EAX, lo;
        mov EDX, hi;
        wrmsr;
    }
}

u64
rdmsr(uint msr) {
    u32 lo, hi;
    asm {
        mov ECX, msr;
        rdmsr;
        mov lo, EAX;
        mov hi, EDX;
    }
    return (cast(ulong)hi << 32) | lo;
}

u8
cpuid_num() {
    u32 ebx;
    asm {
        mov EAX, 1;
        cpuid;
        mov ebx, EBX;
    }
    return cast(u8)((ebx >> 24) & 0xFF);
}

void
outb( u16 port, u8 val ) {
    asm  {
        mov DX, port;
        mov AL, val;
        out DX, AL;
    }
}

void
outl( u16 port, u32 val ) {
    asm  {
        mov DX, port;
        mov EAX, val;
        out DX, EAX;
    }
}

u8
inb( u16 port ) {
    u8 val;
    asm  {
        mov DX, port;
        in AL, DX;
        mov val, AL;
    }
    return val;
}

u32
inl( u16 port ) {
    uint val;
    asm  {
        mov DX, port;
        in EAX, DX;
        mov val, EAX;
    }
    return val;
}

void
io_wait() {
    asm {
        naked;
        xor AL, AL;
        out 0x80, AL;
        ret;
    }
}

void
writeMSR( uint msr, ulong value ) {
    uint lo = cast(uint)(value & 0xFFFF_FFFF);
    uint hi = cast(uint)(value >> 32);
    asm {
        mov ECX, msr;
        mov EAX, lo;
        mov EDX, hi;
        wrmsr;
    }
}

ulong
readMSR( uint msr ) {
    uint lo, hi;
    asm @nogc {
        mov ECX, msr;
        rdmsr;
        mov lo, EAX;
        mov hi, EDX;
    }
    return (cast(ulong) hi << 32) | lo;
}

//
// Enable global pages
//
void cpu_enable_pge() {
    asm {
        mov RAX, CR4;
        or  RAX, 0x80;   // set bit 7 = PGE
        mov CR4, RAX;
    }
}

void
invlpg( ulong va ) {
    asm {
        invlpg [va];
    }

    // TODO: lapicSendShootdownIPI
}

void set_gs_base( ulong base ) {
    writeMSR(0xC0000101, base);

    ulong gsBase  = readMSR(0xC0000101);  // IA32_GS_BASE
    ulong kgsBase = readMSR(0xC0000102);  // IA32_KERNEL_GS_BASE

    ktrace!"MSR base1: %x - %x\n"(gsBase, kgsBase);
    ktrace!"self: %016x\n"(self);
}


struct PerCpu {
    PerCpu* self;       // 0x00 — self-pointer for GS:[0]
    Thread  thread;     // 0x08 — current thread
    ulong   rsp0;       // 0x10 — kernel stack top (for syscall entry)
    ulong   user_rsp;   // 0x18 — saved user RSP during syscall
    uint    cpuid;      // 0x20
}

// Offsets used by assembly (syscall_entry)
enum PERCPU_RSP0     = 0x10;
enum PERCPU_USER_RSP = 0x18;

static assert(PerCpu.self.offsetof    == 0x00);
static assert(PerCpu.thread.offsetof  == 0x08);
static assert(PerCpu.rsp0.offsetof    == PERCPU_RSP0);
static assert(PerCpu.user_rsp.offsetof == PERCPU_USER_RSP);

__gshared PerCpu[MAX_CPUS] percpu;

void
percpu_init() {
    auto cpu = cpuid_num();

    percpu[cpu].self = &percpu[cpu];
    percpu[cpu].cpuid = cpu;

    set_gs_base( cast(ulong)&percpu[cpu] );

    // Set KERNEL_GS_BASE so SWAPGS can switch between user/kernel GS
    writeMSR(0xC0000102, cast(ulong)&percpu[cpu]);  // IA32_KERNEL_GS_BASE
}

@property PerCpu*
self() {
    PerCpu* p;
    asm {
        mov RAX, qword ptr GS:[0];
        mov p, RAX;
    }
    return p;
}

int
current_cpu() {
    return self.cpuid;
}
