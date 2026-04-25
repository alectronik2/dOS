module kern.thread;

import lib.runtime, lib.klog, hal.cpu, hal.serial;
import lib.lock, mm.heap, hal.gdt, hal.idt, mm.pfdb;
import hal.gdt, kern.process, kern.object, kern.sync;

const THREAD_PRIORITY_LEVELS = 32;
const PRIORITY_TIME_CRITICAL = 15;
const DEFAULT_QUANTUM        = 15;

const KERNEL_STACK_SIZE      = PAGE_SIZE * 2;
enum USER_CODE_ADDR          = 0x300000UL;
enum USER_STACK_ADDR         = 0x301000UL;
enum USER_KLOG_MSG_ADDR      = 0x300800UL;
enum USER_KLOG_MSG           = "<Red>Hello</> from user mode!\n";

alias thread_fn = Status function( void* arg );

enum WaitReason {
    Object,
    Buffer,
    Task,
    Socket,
    Sleep,
    Pipe,
    DevIO,
}

class Thread : KObject {
    thread_fn   fn;
    void*       arg;

    uint        priority;
    uint        base_priority;
    uint        quantum;
    uint        suspend_count;
    ThreadState state;
    uint        flags;

    ulong       preempt;

    ThreadContext ctx;
    void*       kernel_stack;
    size_t      kernel_stack_size;

    Process    proc;
    Thread      proc_next;

    Thread      prev_ready;
    Thread      next_ready;

    WaitBlock*  waitlist;
    Status      waitkey;
    WaitReason  wait_reason;

    Status      exitcode;

    this() {

    }

    this( Process proc, thread_fn fn, void* arg, int flags = 0 ) {
        this.fn           = fn;
        this.arg          = arg;

        this.proc         = proc;
        this.proc_next    = this.proc.threads;
        this.proc.threads = this;
        this.proc         = proc;

        this.kernel_stack = kmalloc!void( KERNEL_STACK_SIZE );
        this.kernel_stack_size = KERNEL_STACK_SIZE;

        if( flags & THREAD_USER ) {
            this.ctx.cs   = USER_CS;
            this.ctx.ss   = USER_DS;
            this.ctx.rflags = 0x202;

            this.ctx.rsp  = USER_STACK_ADDR + PAGE_SIZE;
            this.ctx.rip  = USER_CODE_ADDR;

            import mm.pfdb;
            auto user_page  = alloc_pageframe();
            auto user_stack = alloc_pageframe();

            map_page( m.kernel_pml4, USER_CODE_ADDR, user_page << PAGE_SHIFT, Page.Present | Page.Writable | Page.User );
            map_page( m.kernel_pml4, USER_STACK_ADDR, user_stack << PAGE_SHIFT, Page.Present | Page.Writable | Page.User  );

            memcpy( cast(void*)USER_CODE_ADDR, &user_func, 0x100 );
            memcpy( cast(void*)USER_KLOG_MSG_ADDR, USER_KLOG_MSG.ptr, USER_KLOG_MSG.length );

            this.flags |= THREAD_IS_USER_INIT;
        } else {
            this.ctx.cs   = KERNEL_CS;
            this.ctx.ss   = KERNEL_DS;

            auto stack_top = cast(ulong)(this.kernel_stack + this.kernel_stack_size);
            this.ctx.rsp  = (stack_top & ~cast(ulong)0xF) - 8;  // 16-byte align, then -8 for ABI (simulates CALL)
            this.ctx.rip  = cast(ulong)&thread_entry;
            this.ctx.rflags = 0x2;
        }

        this.ctx.rdi    = cast(ulong) arg;

        this.priority   = this.base_priority = PRIORITY_TIME_CRITICAL;
        this.quantum    = DEFAULT_QUANTUM;
        this.suspend_count = 0;
        this.state      = ThreadState.Initialized;

        mark_thread_ready( this, 0, 0 );
    }

    void
    block() {
        this.state = ThreadState.Waiting;
    }

    void
    unblock() {
        mark_thread_ready( this, 0, 0 );
    }
}

enum {
    THREAD_INTERRUPTED  = 1 << 0,

    THREAD_USER         = 1 << 1,
    THREAD_IS_USER_INIT = 1 << 2,

    THREAD_ALERTABLE    = 1 << 3,
}

enum ThreadState {
    Initialized = 0,
    Ready       = 1,
    Running     = 2,
    Suspended   = 3,
    Waiting     = 4,
    Transition  = 5,
    Dead        = 6,
}

private __gshared {
    Thread init_thread;

    Thread[THREAD_PRIORITY_LEVELS] ready_queue_head;
    Thread[THREAD_PRIORITY_LEVELS] ready_queue_tail;

    uint           thread_ready_summary;
    ulong          ticks;
    bool[MAX_CPUS] preempt;

    SpinLock       sched_lock;
}

extern(C) void
thread_entry( void* arg ) {
    enable_interrupts();    // New threads enter via JMP, not IRETQ, so enable interrupts explicitly

    auto t      = current_thread();
    auto fn     = t.fn;
    auto fn_arg = t.arg;

    ktrace!"Thread starting with arg %p\n"(fn_arg);
    auto status = fn( fn_arg );
    ktrace!"Thread exiting with status %i\n"(status);
    t.exitcode = status;
    t.state = ThreadState.Dead;

    if( !thread_ready_summary ) {
        disable_interrupts();
        hang();
    }

    dispatch();

    disable_interrupts();
    hang();
}

Thread
current_thread() {
    return self.thread;
}

private Thread
find_ready_thread( Thread current, u32 cpu ) {
    if( !thread_ready_summary ) {
        klog!"No ready threads!\n";
        return current;
    }

    auto prio = find_highest_bit( thread_ready_summary );
    auto thread = ready_queue_head[prio];

    if( !thread.next_ready ) {
        ready_queue_head[prio] = ready_queue_tail[prio] = null;
        thread_ready_summary &= ~(1 << prio);
    } else {
        thread.next_ready.prev_ready = null;
        ready_queue_head[prio] = thread.next_ready;
    }

    thread.prev_ready = thread.next_ready = null;
    return thread;
}

private void
insert_ready_head( Thread t ) {
    if( !ready_queue_head[t.priority] ) {
        t.next_ready = t.prev_ready = null;
        ready_queue_head[t.priority] = ready_queue_tail[t.priority] = t;
        thread_ready_summary |= (1 << t.priority);
    } else {
        t.next_ready = ready_queue_head[t.priority];
        t.prev_ready = null;
        t.next_ready.prev_ready = t;
        ready_queue_head[t.priority] = t;
    }
}

private void
insert_ready_tail( Thread t ) {
    if( !ready_queue_tail[t.priority] ) {
        t.next_ready = t.prev_ready = null;
        ready_queue_head[t.priority] = ready_queue_tail[t.priority] = t;
        thread_ready_summary |= (1 << t.priority);
    } else {
        t.next_ready = null;
        t.prev_ready = ready_queue_tail[t.priority];
        t.prev_ready.next_ready = t;
        ready_queue_tail[t.priority] = t;
    }
}

private void
remove_from_ready_queue( Thread t ) {
    if( t.next_ready ) t.next_ready.prev_ready = t.prev_ready;
    if( t.prev_ready ) t.prev_ready.next_ready = t.next_ready;
    if( t == ready_queue_head[t.priority] ) ready_queue_head[t.priority] = t.next_ready;
    if( t == ready_queue_tail[t.priority] ) ready_queue_tail[t.priority] = t.prev_ready;
    if( !ready_queue_tail[t.priority]) thread_ready_summary &= ~(1 << t.priority);
}

void
mark_thread_ready( Thread t, int charge, int boost ) {
    int newprio;

    // Check for suspended thread that is now ready to run
    if( t.suspend_count > 0 ) {
        t.state = ThreadState.Suspended;
        return;
    }

    // If thread has been interrupted it is already ready
    if( t.flags & THREAD_INTERRUPTED && t.state == ThreadState.Ready )
        return;

    if( t.quantum ) t.quantum -= charge;

    newprio = t.base_priority + boost;
    if( newprio > PRIORITY_TIME_CRITICAL ) newprio = PRIORITY_TIME_CRITICAL;
    if( newprio > t.priority ) t.priority = newprio;

    auto was_running = (t.state == ThreadState.Running);

    // Set thread state to ready
    if( t.state == ThreadState.Ready ) kpanic!"Thread already ready";
    t.state = ThreadState.Ready;

    // Insert thread in ready queue. A preempted running thread goes to the
    // tail so equal-priority peers actually get CPU time on the next tick.
    if( t.quantum > 0 && !was_running ) {
        insert_ready_head( t );
    } else {
        // The thread has exhausted its CPU quantum. Assign a new quantum
        if( !t.quantum )
            t.quantum = DEFAULT_QUANTUM;

        // Let priority decay towards base priority
        if( t.priority > t.base_priority ) t.priority--;

        insert_ready_tail( t );
    }

    if( t.priority > current_thread().priority )
        preempt[current_cpu()] = true;

    //log_debugn( "Marked thread %s ready.", t.name.ptr );
}

void
dispatch() {
    auto cpu = current_cpu();
    auto curthread = self.thread;

    auto t = find_ready_thread( curthread, cpu );
    assert( t );

    self.thread = t;

    if( t == curthread ) {
        t.state = ThreadState.Running;
        return;
    }

    t.state = ThreadState.Running;

    //klog!"Switching context to %x is_user: %i\n"(t.arg, !!(t.ctx.cs & 0x3) );

    // If switching to a user-mode thread, set TSS.rsp0 and PerCpu.rsp0
    // so that interrupts and syscalls in ring 3 land on the right stack.
    if( t.ctx.cs & 0x3 ) {
        auto kstack_top = cast(ulong)(t.kernel_stack + t.kernel_stack_size);
        tss.rsp0 = kstack_top;
        self.rsp0 = kstack_top;
    }

    if( t.flags & THREAD_IS_USER_INIT ) {
        kdebug!"<Red>Entering user context.</>\n";
        t.flags &= ~THREAD_IS_USER_INIT;
        enter_user( &curthread.ctx, &t.ctx );
    } else
        context_switch( &curthread.ctx, &t.ctx );

    // We resume here when switched back in. curthread (local) is us.
    curthread.state = ThreadState.Running;
}

void
preempt_thread( Context *ctx ) {
    auto t = current_thread();

    // Count number of preempted context switches
    t.preempt++;

    // We are still running on an interrupt frame. Keep IRQs masked until the
    // chosen thread restores its own execution context; otherwise nested
    // interrupts can corrupt the in-flight return path.
    save_interrupt_context( t, ctx );

    // Assign a new quantum if quantum expired
    if( t.quantum <= 0 ) {
        t.quantum = DEFAULT_QUANTUM;
        if( t.priority > t.base_priority ) t.priority--;
    }

    // Thread is ready to run
    t.state = ThreadState.Ready;
    insert_ready_tail( t );

    dispatch();
}

private void
save_interrupt_context( Thread t, Context* ctx ) {
    t.ctx.r15 = ctx.r15;
    t.ctx.r14 = ctx.r14;
    t.ctx.r13 = ctx.r13;
    t.ctx.r12 = ctx.r12;
    t.ctx.r11 = ctx.r11;
    t.ctx.r10 = ctx.r10;
    t.ctx.r9  = ctx.r9;
    t.ctx.r8  = ctx.r8;
    t.ctx.rdi = ctx.rdi;
    t.ctx.rsi = ctx.rsi;
    t.ctx.rbp = ctx.rbp;
    t.ctx.rbx = ctx.rbx;
    t.ctx.rdx = ctx.rdx;
    t.ctx.rcx = ctx.rcx;
    t.ctx.rax = ctx.rax;

    t.ctx.rip    = ctx.rip;
    t.ctx.cs     = ctx.cs;
    t.ctx.rflags = ctx.rflags;

    t.ctx.rsp = ctx.rsp;
    t.ctx.ss  = ctx.ss ? ctx.ss : KERNEL_DS;
}

Status
set_threead_priority( Thread t, int priority ) {
    if( priority < 0 || priority > THREAD_PRIORITY_LEVELS ) return Status.Inval;
    if( t.base_priority == priority ) return Status.Ok;

    if( t == current_thread() ) {
        // Thread changed priority for itself, reschedule if new priority lower
        if( priority < t.priority ) {
            t.base_priority = t.priority = priority;
            mark_thread_ready( t, 0, 0 );
            dispatch();
        } else {
            t.base_priority = t.priority = priority;
        }
    } else {
        // If thread is ready to run, remove it from the current ready queue
        // and insert the ready queue for the new priority
        if( t.state == ThreadState.Ready ) {
            remove_from_ready_queue( t );
            t.base_priority = t.priority = priority;
            t.state = ThreadState.Transition;
            mark_thread_ready( t, 0, 0 );
        } else {
            t.base_priority = t.priority = priority;
        }
    }

    return Status.Ok;
}

__gshared Mutex mutex;

Status
thread1( void* arg ) {
    klog!"Thread 1 started, acquiring mutex... (will block)\n";
    mutex.acquire();
    klogf!"done.\n";

    //mutex.release();
    klog!"Thread 1 released mutex, exiting.\n";

    return Status.Ok;
}

Status
thread2( void* arg ) {
    klog!"Thread 2 started, acquiring mutex... ";
    mutex.acquire();
    //mutex.release();
    klogf!"done.\n";

    return Status.Ok;
}

Status
user_func() {
    auto msg_ptr = cast(const(char)*)USER_KLOG_MSG_ADDR;
    auto msg_length = USER_KLOG_MSG.length;

    asm {
            mov RDI, msg_ptr;
            mov RSI, msg_length;
            mov RAX, 0;    // SYS_KLOG
            syscall;

            mov RDI, 0;    // status code
            mov RAX, 1;    // SYS_ExitThread
            syscall;
        }
    while (true) {} // shiould never reach here
}

__gshared {
    ThreadContext init_context;
}

void
thread_exit( Status code ) {
    auto t = current_thread();
    t.exitcode = code;
    t.state = ThreadState.Dead;

    dispatch();
    hang();
}

void
thread_init() {
    klog!"thread_init()\n";
    assert( kernel_process !is null, "thread_init: kernel process is not initialized" );

    init_thread = new Thread();
    init_thread.priority = init_thread.base_priority = PRIORITY_TIME_CRITICAL;
    init_thread.quantum = DEFAULT_QUANTUM;
    init_thread.state = ThreadState.Running;

    ktrace!"init_thread created\n";
    self.thread = init_thread;
    init_thread.arg = cast(void*)0xAAAA;

    mutex = new Mutex();

    auto t1 = new Thread( kernel_process, &thread1, cast(void*)0xDEAD );
    klog!"Created thread %x with priority %i\n"(t1.arg, t1.priority);
    auto t2 = new Thread( kernel_process, &thread2, cast(void*)0xBEEF );
    klog!"Created thread %x with priority %i\n"(t2.arg, t2.priority);

    auto t4 = new Thread( kernel_process, null, null, THREAD_USER );
}

struct ThreadContext {
    u64 r15;      // 0x00
    u64 r14;      // 0x08
    u64 r13;      // 0x10
    u64 r12;      // 0x18
    u64 rdi;      // 0x20
    u64 rbp;      // 0x28
    u64 rbx;      // 0x30
    u64 rip;      // 0x38
    u64 rflags;   // 0x40
    u64 rsp;      // 0x48
    u64 cs;       // 0x50
    u64 ss;       // 0x58
    u64 r11;      // 0x60
    u64 r10;      // 0x68
    u64 r9;       // 0x70
    u64 r8;       // 0x78
    u64 rsi;      // 0x80
    u64 rdx;      // 0x88
    u64 rcx;      // 0x90
    u64 rax;      // 0x98
}

void
context_switch(ThreadContext *old, ThreadContext *new_) {
    asm {
        naked;

        // Save old context
        mov [RDI + 0x00], R15;
        mov [RDI + 0x08], R14;
        mov [RDI + 0x10], R13;
        mov [RDI + 0x18], R12;
        mov [RDI + 0x20], RDI;
        mov [RDI + 0x28], RBP;
        mov [RDI + 0x30], RBX;

        mov RAX, [RSP];
        mov [RDI + 0x38], RAX;

        pushfq;
        popq [RDI + 0x40];
        mov qword ptr [RDI + 0x50], 0x08;
        mov qword ptr [RDI + 0x58], 0x10;

        lea RAX, [RSP + 8];
        mov [RDI + 0x48], RAX;

        // Load new context
        mov R11, RSI;

        mov R15, [R11 + 0x00];
        mov R14, [R11 + 0x08];
        mov R13, [R11 + 0x10];
        mov R12, [R11 + 0x18];
        mov RDI, [R11 + 0x20];
        mov RBP, [R11 + 0x28];
        mov RBX, [R11 + 0x30];

        // RFLAGS is saved above for later IRET-based resumes. It is not
        // restored for direct JMP-based switches.

        mov RSP, [R11 + 0x48];

        mov RAX, [R11 + 0x38];
        jmp RAX;
    }
}

extern(C) void
context_enter( ThreadContext* ctx ) {
    asm {
        naked;

        mov R11, RDI;
        test byte ptr [R11 + 0x50], 0x3;
        jnz restore_user;

        // Resume a kernel thread by switching to its saved kernel stack and
        // synthesizing the full long-mode IRET frame there.
        mov R10, [R11 + 0x48];
        lea RSP, [R10 - 40];
        mov RAX, [R11 + 0x38];
        mov [RSP], RAX;
        mov RAX, [R11 + 0x50];
        mov [RSP + 8], RAX;
        mov RAX, [R11 + 0x40];
        mov [RSP + 16], RAX;
        mov RAX, [R11 + 0x48];
        mov [RSP + 24], RAX;
        mov RAX, [R11 + 0x58];
        mov [RSP + 32], RAX;

        mov R15, [R11 + 0x00];
        mov R14, [R11 + 0x08];
        mov R13, [R11 + 0x10];
        mov R12, [R11 + 0x18];
        mov RDI, [R11 + 0x20];
        mov RBP, [R11 + 0x28];
        mov RBX, [R11 + 0x30];
        mov R9,  [R11 + 0x70];
        mov R8,  [R11 + 0x78];
        mov RSI, [R11 + 0x80];
        mov RDX, [R11 + 0x88];
        mov RCX, [R11 + 0x90];
        mov RAX, [R11 + 0x98];
        mov R10, [R11 + 0x68];
        mov R11, [R11 + 0x60];
        iretq;

restore_user:
        // Resume a user thread by synthesizing an IRET frame on the current
        // kernel stack and returning to ring 3.
        mov AX, [R11 + 0x58];
        mov DS, AX;
        mov ES, AX;

        pushq [R11 + 0x58];
        pushq [R11 + 0x48];
        pushq [R11 + 0x40];
        pushq [R11 + 0x50];
        pushq [R11 + 0x38];

        mov R15, [R11 + 0x00];
        mov R14, [R11 + 0x08];
        mov R13, [R11 + 0x10];
        mov R12, [R11 + 0x18];
        mov RDI, [R11 + 0x20];
        mov RBP, [R11 + 0x28];
        mov RBX, [R11 + 0x30];
        mov R9,  [R11 + 0x70];
        mov R8,  [R11 + 0x78];
        mov RSI, [R11 + 0x80];
        mov RDX, [R11 + 0x88];
        mov RCX, [R11 + 0x90];
        mov RAX, [R11 + 0x98];
        mov R10, [R11 + 0x68];
        mov R11, [R11 + 0x60];

        iretq;
    }
}

void
enter_user(ThreadContext *old, ThreadContext *ctx) {
    asm {
        naked;

        // Save old context
        mov [RDI + 0x00], R15;
        mov [RDI + 0x08], R14;
        mov [RDI + 0x10], R13;
        mov [RDI + 0x18], R12;
        mov [RDI + 0x20], RDI;
        mov [RDI + 0x28], RBP;
        mov [RDI + 0x30], RBX;

        pushfq;
        popq [RDI + 0x40];
        mov qword ptr [RDI + 0x50], 0x08;
        mov qword ptr [RDI + 0x58], 0x10;

        mov RAX, [RSP];
        mov [RDI + 0x38], RAX;

        lea RAX, [RSP + 8];
        mov [RDI + 0x48], RAX;

        // Load new context
        mov R11, RSI;

        mov AX, [R11 + 0x58];
        mov DS, AX;
        mov ES, AX;

        pushq [R11 + 0x58]; // SS
        pushq [R11 + 0x48]; // RSP
        pushq [R11 + 0x40]; // RFLAGS
        pushq [R11 + 0x50]; // CS
        pushq [R11 + 0x38]; // RIP

        mov R15, [R11 + 0x00];
        mov R14, [R11 + 0x08];
        mov R13, [R11 + 0x10];
        mov R12, [R11 + 0x18];
        mov RDI, [R11 + 0x20];
        mov RBP, [R11 + 0x28];
        mov RBX, [R11 + 0x30];
        mov R9,  [R11 + 0x70];
        mov R8,  [R11 + 0x78];
        mov RSI, [R11 + 0x80];
        mov RDX, [R11 + 0x88];
        mov RCX, [R11 + 0x90];
        mov RAX, [R11 + 0x98];
        mov R10, [R11 + 0x68];
        mov R11, [R11 + 0x60];

        iretq;
    }
}
