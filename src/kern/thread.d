module kern.thread;

import lib.runtime, lib.print, hal.cpu, hal.serial;
import lib.lock, mm.heap, hal.gdt, hal.idt;
import hal.gdt, kern.process, kern.object;

const THREAD_PRIORITY_LEVELS = 32;
const PRIORITY_TIME_CRITICAL = 15;
const DEFAULT_QUANTUM        = 15;

const KERNEL_STACK_SIZE      = PAGE_SIZE * 2;

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

    Process*    proc;
    Thread      proc_next;

    Thread      prev_ready;
    Thread      next_ready;

    WaitBlock*  waitlist;
    Status      waitkey;
    WaitReason  wait_reason;

    Status      exitcode;

    this() {

    }

    this( Process* proc, thread_fn fn, void* arg, int flags = 0 ) {
        this.type         = KObjectType.Thread;

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

            this.ctx.rsp  = 0x301000 + 0x1000;
            this.ctx.rip  = 0x300000;

            import mm.pfdb;
            auto user_page  = alloc_pageframe();
            auto user_stack = alloc_pageframe();

            map_page( kernel_pml4, 0x300000, user_page << PAGE_SHIFT, Page.Present | Page.Writable | Page.User );
            map_page( kernel_pml4, 0x301000, user_stack << PAGE_SHIFT, Page.Present | Page.Writable | Page.User  );

            memcpy( cast(void*)0x300000, &user_func, 0x100 );

            this.flags |= THREAD_IS_USER_INIT;
        } else {
            this.ctx.cs   = KERNEL_CS;
            this.ctx.ss   = KERNEL_DS;

            auto stack_top = cast(ulong)(this.kernel_stack + this.kernel_stack_size);
            this.ctx.rsp  = (stack_top & ~cast(ulong)0xF) - 8;  // 16-byte align, then -8 for ABI (simulates CALL)
            this.ctx.rip  = cast(ulong)&thread_entry;
        }

        this.ctx.rdi    = cast(ulong) arg;
        this.ctx.rflags = 0x202;        

        this.priority   = this.base_priority = PRIORITY_TIME_CRITICAL;
        this.quantum    = DEFAULT_QUANTUM;
        this.suspend_count = 0;
        this.state      = ThreadState.Initialized;

        mark_thread_ready( this, 0, 0 );
    }
}

enum {
    THREAD_INTERRUPTED  = 1 << 0,

    THREAD_USER         = 1 << 1,
    THREAD_IS_USER_INIT = 1 << 2,
}

enum ThreadState {
    Initialized = 0,
    Ready       = 1,
    Running     = 2,
    Suspended   = 3,
    Waiting     = 4,
    Dead        = 5,
}

private __gshared {
    Thread init_thread;

    Thread[THREAD_PRIORITY_LEVELS] ready_queue_head;
    Thread[THREAD_PRIORITY_LEVELS] ready_queue_tail;

    uint thread_ready_summary;
    ulong ticks;

    SpinLock sched_lock;
}

extern(C) void
thread_entry( void* arg ) {
    enable_interrupts();    // New threads enter via JMP, not IRETQ, so enable interrupts explicitly

    auto t      = current_thread();
    auto fn     = t.fn;
    auto fn_arg = t.arg;

    kprintf( "Thread starting with arg {p}\n", fn_arg );
    auto status = fn( fn_arg );
    t.state = ThreadState.Dead;
    kprintf( "Thread exiting with status {i}\n", status );

    hang(); // TODO
}

Thread
current_thread() {
    return self.thread;
}

private Thread
find_ready_thread( Thread current, u32 cpu ) {
    if( !thread_ready_summary ) {
        kprintf( "No ready threads!\n" );
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
    if( t.state == ThreadState.Ready ) kpanic( "Thread already ready" );
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

    //if( t.priority > current_thread().priority )
     //   preempt[current_cpu()] = true;

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

    //kprintf( "Switching context to {x} is_user: {i}\n", t.arg, !!(t.ctx.cs & 0x3) );

    // If switching to a user-mode thread, set TSS.rsp0 to its kernel
    // stack so that interrupts in ring 3 land on the right stack.
    if( t.ctx.cs & 0x3 ) {
        tss.rsp0 = cast(ulong)(t.kernel_stack + t.kernel_stack_size);
    }

    if( t.flags & THREAD_IS_USER_INIT ) {
        t.flags &= ~THREAD_IS_USER_INIT;
        enter_user( &curthread.ctx, &t.ctx );
    } else
        context_switch( &curthread.ctx, &t.ctx );

    // We resume here when switched back in. curthread (local) is us.
    curthread.state = ThreadState.Running;
}

void
preempt_thread() {
    auto t = current_thread();

    t.preempt++;

    if( t.quantum <= 0 ) {
        t.quantum = DEFAULT_QUANTUM;
        if( t.priority > t.base_priority ) t.priority--;
    }

    t.state = ThreadState.Ready;
    insert_ready_tail( t );

    dispatch();
}

Status 
func( void* arg ) {
    while( true ) {
        disable_interrupts();
        if( arg == cast(void*)0xDEAD ) {
            serial_write( "DEAD " );
        } else if( arg == cast(void*)0xBEEF ) {
            serial_write( "BEEF " );
        } else if( arg == cast(void*)0xFEED ) {
            serial_write( "FEED " );
        } else {
            serial_write( "???? " );
        }
        enable_interrupts();

        asm { hlt; }
    }
    return Status.Ok;
}

void
user_func() {
    while(true) {
        asm { int 0x80; }
    }
}

__gshared {
    u8[4096]      thread_stack;
    ThreadContext init_context;
    Process       kernel_process;
}

void
thread_init() {
    init_thread = new Thread();
    //init_thread.priority = init_thread.base_priority = PRIORITY_TIME_CRITICAL;

    self.thread = init_thread;
    init_thread.arg = cast(void*)0xAAAA;

    auto t1 = new Thread( &kernel_process, &func, cast(void*)0xDEAD );
    kprintf( "Created thread {x} with priority {i}\n", t1.arg, t1.priority );

    auto t2 = new Thread( &kernel_process, &func, cast(void*)0xBEEF );
    kprintf( "Created thread {x} with priority {i}\n", t2.arg, t2.priority );

    auto t3 = new Thread( &kernel_process, &func, cast(void*)0xFEED );
    kprintf( "Created thread {x} with priority {i}\n", t3.arg, t3.priority );

    auto t4 = new Thread( &kernel_process, null, null, THREAD_USER );
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

        // RFLAGS is NOT restored here — interrupts must stay disabled
        // during the switch. IRETQ in isr_common restores the original
        // RFLAGS; new threads call enable_interrupts() in thread_entry.

        mov RSP, [R11 + 0x48];

        mov RAX, [R11 + 0x38];
        jmp RAX;
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

        mov RBX, [R11 + 0x30];

        iretq;
    }
}

void
enter_wait( WaitReason reason ) {
    auto t = current_thread();

    t.state = ThreadState.Waiting;
    t.wait_reason = reason;

    dispatch();
}

Status
enter_alertable_wait( WaitReason reason ) {
    auto t = current_thread();
    // TODO
    return Status.Ok;
}