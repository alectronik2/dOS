module hal.idt;

import lib.klog, kern.dbg;
import hal.gdt, hal.cpu, hal.pic, hal.serial;
import kern.thread, kern.dbg;

/**
 * cpu.d — CPU-level data structures shared across modules.
 *
 * Memory layout at entry to isr_common / timer_entry handlers
 * (lowest address = RSP, highest = SS pushed first by CPU):
 *
 *   [RSP+  0]  r15          ← RSP when isr_handler / timer_handler called
 *   [RSP+  8]  r14
 *   [RSP+ 16]  r13
 *   [RSP+ 24]  r12
 *   [RSP+ 32]  r11
 *   [RSP+ 40]  r10
 *   [RSP+ 48]  r9
 *   [RSP+ 56]  r8
 *   [RSP+ 64]  rdi
 *   [RSP+ 72]  rsi
 *   [RSP+ 80]  rbp
 *   [RSP+ 88]  rbx
 *   [RSP+ 96]  rdx
 *   [RSP+104]  rcx
 *   [RSP+112]  rax          ← pushed first by isr_common
 *   [RSP+120]  vector       ← pushed by ISR stub
 *   [RSP+128]  error_code   ← real (err exceptions) or 0 (dummy)
 *   [RSP+136]  rip          \
 *   [RSP+144]  cs            |  pushed by CPU (always in 64-bit mode)
 *   [RSP+152]  rflags        |
 *   [RSP+160]  rsp           |
 *   [RSP+168]  ss           /
 *
 * Total: 22 × 8 = 176 bytes.
 */

struct Context {
    u64 r15, r14, r13, r12, r11, r10, r9, r8;
    u64 rdi, rsi, rbp, rbx, rdx, rcx, rax;

    u64 vector;
    u64 error_code;

    /* Long-mode CPU interrupt frame: RIP, CS, RFLAGS, RSP, SS. */
    u64 rip;
    u64 cs;
    u64 rflags;
    u64 rsp;

    u64 ss;
}

extern(C) void context_enter( Context* ctx );

struct idt_entry {
align(1):
    u16 offset_low;    /// handler address bits 15:0
    u16 selector;      /// code-segment selector (0x08)
    u8  ist;           /// Interrupt Stack Table index (0 = none)
    u8  type_attr;     /// gate type / DPL / present
    u16 offset_mid;    /// handler address bits 31:16
    u32 offset_high;   /// handler address bits 63:32
    u32 reserved;
}
static assert(idt_entry.sizeof == 16, "IDTEntry must be exactly 16 bytes");

struct IDTR {
align(1):
    u16 limit;
    u64  base;
}
static assert(IDTR.sizeof == 10, "IDTR must be exactly 10 bytes");

enum {
    GATE_INTERRUPT = 0x8E,  /// P=1 DPL=0 type=0xE — clears IF
    GATE_TRAP      = 0x8F,  /// P=1 DPL=0 type=0xF — preserves IF
    GATE_USER_INT  = 0xEE,  /// P=1 DPL=3 type=0xE — ring-3 callable
}

private const NUM_VECTORS = 256;

__gshared {
    align(16) idt_entry[NUM_VECTORS] idt_table;
    align(4)  IDTR                   idt_ptr;

    Interrupt*[NUM_VECTORS]          intrhndlr;
}

alias intrproc_t = Status function( void *arg );

struct Interrupt {
    Interrupt *next;
    int flags;
    int intrno;
    intrproc_t handler;
    void *arg;

    void
    register( int intrno, intrproc_t f, void* arg = null ) {
        assert( intrno < NUM_VECTORS );

        this.handler = f;
        this.arg = arg;
        this.flags = 0;
        this.intrno = intrno;
        this.next = intrhndlr[intrno];
        intrhndlr[intrno] = &this;
    }

    void
    unregister() {
        Interrupt *i;

        if( intrhndlr[intrno] == &this ) {
            intrhndlr[intrno] = next;
        } else {
            for( i = intrhndlr[intrno]; i != null; i = i.next ) {
                if( i.next == &this ) {
                    i.next = next;
                    break;
                }
            }
        }
        next = null;
    }
}

private idt_entry
make_gate( ulong handler, ubyte type_attr, ubyte ist = 0 ) {
    idt_entry e;

    e.offset_low  = cast(ushort)( handler         & 0xFFFF);
    e.selector    = KERNEL_CS;
    e.ist         = ist;
    e.type_attr   = type_attr;
    e.offset_mid  = cast(ushort)((handler >> 16)  & 0xFFFF);
    e.offset_high = cast(uint)  ((handler >> 32)  & 0xFFFF_FFFF);
    e.reserved    = 0;

    return e;
}

void
idt_flush( IDTR* idt ) {
    asm {
        naked;
        lidt [RDI];
        ret;
    }
}

void
idt_init() {
    idt_table[ 0] = make_gate(cast(ulong)&isr0,  GATE_INTERRUPT);
    idt_table[ 1] = make_gate(cast(ulong)&isr1,  GATE_TRAP);       /* #DB  */
    idt_table[ 2] = make_gate(cast(ulong)&isr2,  GATE_INTERRUPT);  /* NMI  */
    idt_table[ 3] = make_gate(cast(ulong)&isr3,  GATE_TRAP);       /* #BP  */
    idt_table[ 4] = make_gate(cast(ulong)&isr4,  GATE_TRAP);       /* #OF  */
    idt_table[ 5] = make_gate(cast(ulong)&isr5,  GATE_INTERRUPT);
    idt_table[ 6] = make_gate(cast(ulong)&isr6,  GATE_INTERRUPT);
    idt_table[ 7] = make_gate(cast(ulong)&isr7,  GATE_INTERRUPT);
    idt_table[ 8] = make_gate(cast(ulong)&isr8,  GATE_INTERRUPT, 1);
    idt_table[ 9] = make_gate(cast(ulong)&isr9,  GATE_INTERRUPT);
    idt_table[10] = make_gate(cast(ulong)&isr10, GATE_INTERRUPT);
    idt_table[11] = make_gate(cast(ulong)&isr11, GATE_INTERRUPT);
    idt_table[12] = make_gate(cast(ulong)&isr12, GATE_INTERRUPT);
    idt_table[13] = make_gate(cast(ulong)&isr13, GATE_INTERRUPT);  /* #GP  */
    idt_table[14] = make_gate(cast(ulong)&isr14, GATE_INTERRUPT);  /* #PF  */
    idt_table[15] = make_gate(cast(ulong)&isr15, GATE_INTERRUPT);
    idt_table[16] = make_gate(cast(ulong)&isr16, GATE_INTERRUPT);
    idt_table[17] = make_gate(cast(ulong)&isr17, GATE_INTERRUPT);
    idt_table[18] = make_gate(cast(ulong)&isr18, GATE_INTERRUPT);
    idt_table[19] = make_gate(cast(ulong)&isr19, GATE_INTERRUPT);
    idt_table[20] = make_gate(cast(ulong)&isr20, GATE_INTERRUPT);
    idt_table[21] = make_gate(cast(ulong)&isr21, GATE_INTERRUPT);
    idt_table[22] = make_gate(cast(ulong)&isr22, GATE_INTERRUPT);
    idt_table[23] = make_gate(cast(ulong)&isr23, GATE_INTERRUPT);
    idt_table[24] = make_gate(cast(ulong)&isr24, GATE_INTERRUPT);
    idt_table[25] = make_gate(cast(ulong)&isr25, GATE_INTERRUPT);
    idt_table[26] = make_gate(cast(ulong)&isr26, GATE_INTERRUPT);
    idt_table[27] = make_gate(cast(ulong)&isr27, GATE_INTERRUPT);
    idt_table[28] = make_gate(cast(ulong)&isr28, GATE_INTERRUPT);
    idt_table[29] = make_gate(cast(ulong)&isr29, GATE_INTERRUPT);
    idt_table[30] = make_gate(cast(ulong)&isr30, GATE_INTERRUPT);
    idt_table[31] = make_gate(cast(ulong)&isr31, GATE_INTERRUPT);

    idt_table[32] = make_gate(cast(ulong)&isr32, GATE_INTERRUPT);
    idt_table[33] = make_gate(cast(ulong)&isr33, GATE_INTERRUPT);
    idt_table[34] = make_gate(cast(ulong)&isr34, GATE_INTERRUPT);
    idt_table[35] = make_gate(cast(ulong)&isr35, GATE_INTERRUPT);
    idt_table[36] = make_gate(cast(ulong)&isr36, GATE_INTERRUPT);
    idt_table[37] = make_gate(cast(ulong)&isr37, GATE_INTERRUPT);
    idt_table[38] = make_gate(cast(ulong)&isr38, GATE_INTERRUPT);
    idt_table[39] = make_gate(cast(ulong)&isr39, GATE_INTERRUPT);
    idt_table[40] = make_gate(cast(ulong)&isr40, GATE_INTERRUPT);
    idt_table[41] = make_gate(cast(ulong)&isr41, GATE_INTERRUPT);
    idt_table[42] = make_gate(cast(ulong)&isr42, GATE_INTERRUPT);
    idt_table[43] = make_gate(cast(ulong)&isr43, GATE_INTERRUPT);
    idt_table[44] = make_gate(cast(ulong)&isr44, GATE_INTERRUPT);
    idt_table[45] = make_gate(cast(ulong)&isr45, GATE_INTERRUPT);
    idt_table[46] = make_gate(cast(ulong)&isr46, GATE_INTERRUPT);
    idt_table[47] = make_gate(cast(ulong)&isr47, GATE_INTERRUPT);
    idt_table[128] = make_gate(cast(ulong)&isr128, GATE_USER_INT);
    idt_table[129] = make_gate(cast(ulong)&isr129, GATE_INTERRUPT);

    idt_ptr.limit = cast(ushort)(idt_entry.sizeof * NUM_VECTORS - 1);
    idt_ptr.base  = cast(ulong)idt_table.ptr;
    idt_flush( &idt_ptr );

    wrmsr( 0xC0000080, rdmsr(0xC0000080) | 1 ); // EFER.SCE
    // STAR: SYSRET CS base in [63:48] = 0x18 (so +16=0x28=user CS, +8=0x20=user DS)
    //       SYSCALL CS in [31:16] = KERNEL_CS
    wrmsr( 0xC0000081, (0x18UL << 48) | (cast(u64)KERNEL_CS << 32) );
    wrmsr( 0xC0000082, cast(u64)&syscall_entry );
    wrmsr( 0xC0000084, 0x600 ); // SFMASK: mask IF (bit 9) and DF (bit 10)
}

void
syscall_entry() {
    asm {
        naked;

        // GS currently points to user GS; swap to kernel PerCpu
        swapgs;

        // Save user RSP in PerCpu.user_rsp, load kernel stack
        mov [GS:0x18], RSP;
        mov RSP, [GS:0x10];

        // Build SyscallFrame on kernel stack
        // (push order = struct field order reversed, lowest addr = first field)
        push RAX;           // syscall number
        push RDI;           // arg1
        push RSI;           // arg2
        push RDX;           // arg3
        push R10;           // arg4 (rcx clobbered by SYSCALL)
        push R8;            // arg5
        push R9;            // arg6
        push RCX;           // user RIP (saved by SYSCALL hw)
        push R11;           // user RFLAGS (saved by SYSCALL hw)

        // push saved user RSP from PerCpu
        push [GS:0x18];

        push RBX;           // callee-saved regs
        push RBP;
        push R12;
        push R13;
        push R14;
        push R15;

        mov RDI, RSP;       // arg0 = SyscallFrame*
        call syscall_dispatch;

        pop R15;
        pop R14;
        pop R13;
        pop R12;
        pop RBP;
        pop RBX;
        add RSP, 8;         // skip saved user_rsp
        pop R11;            // restore RFLAGS -> R11
        pop RCX;            // restore RIP -> RCX
        pop R9;
        pop R8;
        pop R10;
        pop RDX;
        pop RSI;
        pop RDI;
        add RSP, 8;         // skip saved RAX (return value in RAX)

        mov RSP, [GS:0x18]; // restore user RSP
        swapgs;              // swap back to user GS
        sysretq;
    }
}

extern(C) ulong syscall_dispatch(void*);

void
isr_common() {
    asm {
        naked;

        /* Check if we came from ring 3 by testing CS on the interrupt frame.
         * At this point: [RSP+0] = vector, [RSP+8] = error_code,
         *                [RSP+16] = RIP, [RSP+24] = CS.
         * If CS low 2 bits are nonzero, we came from user mode → SWAPGS. */
        test byte ptr [RSP + 24], 0x3;
        jz no_swapgs_entry;
        swapgs;
    no_swapgs_entry:

        /* The long-mode CPU frame is RIP, CS, RFLAGS, RSP, SS. */
        push RAX;
        push RCX;
        push RDX;
        push RBX;
        push RBP;
        push RSI;
        push RDI;
        push R8;
        push R9;
        push R10;
        push R11;
        push R12;
        push R13;
        push R14;
        push R15;

        mov RDI, RSP;  /* RDI = pointer to Context (first arg per SysV ABI). */
        call isr_handler;

        pop R15;
        pop R14;
        pop R13;
        pop R12;
        pop R11;
        pop R10;
        pop R9;
        pop R8;
        pop RDI;
        pop RSI;
        pop RBP;
        pop RBX;
        pop RDX;
        pop RCX;
        pop RAX;
        /* Drop the synthetic vector/error-code pair before returning to the
         * CPU-pushed interrupt frame. */
        add RSP, 16;

        /* If returning to ring 3, swap GS back to user GS.
         * Now [RSP+0] = RIP, [RSP+8] = CS. */
        test byte ptr [RSP + 8], 0x3;
        jz no_swapgs_exit;
        swapgs;
    no_swapgs_exit:
        iretq;
    }
}

template GenISR( string num ) {
    const char[] GenISR = "void isr" ~ num ~ "() {" ~
        "   asm { naked; " ~
        "       push 0;" ~
        "       push " ~ num ~ ";" ~
        "       jmp isr_common;" ~
        "   }" ~
        "}";
}

template GenISRerr( string num ) {
    const char[] GenISRerr = "void isr" ~ num ~ "() {" ~
        "   asm { naked; " ~
        "       push " ~ num ~ ";" ~
        "       jmp isr_common;" ~
        "   }" ~
        "}";
}

mixin( GenISR!("0") );      /* #DE  Divide Error               */
mixin( GenISR!("1") );      /* #DB  Debug                      */
mixin( GenISR!("2") );      /*      NMI                        */
mixin( GenISR!("3") );      /* #BP  Breakpoint                 */
mixin( GenISR!("4") );      /* #OF  Overflow                   */
mixin( GenISR!("5") );      /* #BR  Bound Range Exceeded       */
mixin( GenISR!("6") );      /* #UD  Invalid Opcode             */
mixin( GenISR!("7") );      /* #NM  Device Not Available       */
mixin( GenISRerr!("8") );   /* #DF  Double Fault          *err */
mixin( GenISR!("9") );      /* (reserved)                     */
mixin( GenISRerr!("10") );  /* #TS  Invalid TSS           *err */
mixin( GenISRerr!("11") );  /* #NP  Segment Not Present   *err */
mixin( GenISRerr!("12") );  /* #SS  Stack-Segment Fault   *err */
mixin( GenISRerr!("13") );  /* #GP  General Protection    *err */
mixin( GenISRerr!("14") );  /* #PF  Page Fault            *err */
mixin( GenISR!("15") );     /* (reserved)                     */
mixin( GenISR!("16") );     /* #MF  x87 FP Exception          */
mixin( GenISRerr!("17") );  /* #AC  Alignment Check       *err */
mixin( GenISR!("18") );     /* #MC  Machine Check             */
mixin( GenISR!("19") );     /* #XM  SIMD FP Exception         */
mixin( GenISR!("20") );     /* #VE  Virtualisation            */
mixin( GenISRerr!("21") );  /* #CP  Control Protection    *err */
mixin( GenISR!("22") );
mixin( GenISR!("23") );
mixin( GenISR!("24") );
mixin( GenISR!("25") );
mixin( GenISR!("26") );
mixin( GenISR!("27") );
mixin( GenISR!("28") );
mixin( GenISRerr!("29") ); /* #VC  VMM Communication     *err */
mixin( GenISRerr!("30") ); /* #SX  Security Exception    *err */
mixin( GenISR!("31") );

mixin( GenISR!("32") );
mixin( GenISR!("33") );
mixin( GenISR!("34") );
mixin( GenISR!("35") );
mixin( GenISR!("36") );
mixin( GenISR!("37") );
mixin( GenISR!("38") );
mixin( GenISR!("39") );
mixin( GenISR!("40") );
mixin( GenISR!("41") );
mixin( GenISR!("42") );
mixin( GenISR!("43") );
mixin( GenISR!("44") );
mixin( GenISR!("45") );
mixin( GenISR!("46") );
mixin( GenISR!("47") );
mixin( GenISR!("128") );
mixin( GenISR!("129") );

private const(char)[]
exception_name( ulong vec ) {
    switch( vec ) {
        case  0: return "Divide Error (#DE)";
        case  1: return "Debug (#DB)";
        case  2: return "Non-Maskable Interrupt";
        case  3: return "Breakpoint (#BP)";
        case  4: return "Overflow (#OF)";
        case  5: return "Bound Range Exceeded (#BR)";
        case  6: return "Invalid Opcode (#UD)";
        case  7: return "Device Not Available (#NM)";
        case  8: return "Double Fault (#DF)";
        case  9: return "Coprocessor Segment Overrun";
        case 10: return "Invalid TSS (#TS)";
        case 11: return "Segment Not Present (#NP)";
        case 12: return "Stack-Segment Fault (#SS)";
        case 13: return "General Protection Fault (#GP)";
        case 14: return "Page Fault (#PF)";
        case 16: return "x87 FP Exception (#MF)";
        case 17: return "Alignment Check (#AC)";
        case 18: return "Machine Check (#MC)";
        case 19: return "SIMD FP Exception (#XM)";
        case 20: return "Virtualisation (#VE)";
        case 21: return "Control Protection (#CP)";
        case 29: return "VMM Communication (#VC)";
        case 30: return "Security Exception (#SX)";
        default: return "(reserved)";
    }
}

extern(C) void
isr_handler( Context* ctx ) {
    auto vec = ctx.vector;

    if( vec < 32 ) {
        auto cr2 = read_cr2();

        klogf!"<Red>=[ Interrupt ]=====================================================================================</>\n";
        klogf!"%s\n"(exception_name(vec).ptr);
        klogf!"  vector       =    %16i | error_code     =   %i\n"(vec, ctx.error_code);
        klogf!"  RIP          = 0x%016x | EFLAGS         = 0x%016x\n"(ctx.rip, ctx.rflags);
        klogf!"  CR2          = 0x%016x\n"(cr2);

        auto interruptedFrame = cast(StackFrame*) ctx.rbp;
        //printStackTrace(interruptedFrame);

        hang();
    } else if( vec == 128 ) {
        klog!"syscall 0x80\n";
    } else if( vec == 129 ) {
        klog!"CS: {x}"(ctx.cs);
        while( true ) {}
    } else {
        auto intr = intrhndlr[ vec ];
        while( intr ) {
            auto rc = intr.handler( intr.arg );
            if( rc < 0 ) break;
            intr = intr.next;
        }

        pic_eoi( vec - 32 );
        preempt_thread( ctx );
    }
}
