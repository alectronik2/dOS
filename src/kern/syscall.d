module kern.syscall;

import lib.klog, mm.pfdb;

struct SyscallFrame {
    // Matches push order in syscall_entry (lowest address = first field)
    ulong r15, r14, r13, r12, rbp, rbx;
    ulong user_rsp;
    ulong user_rflags;  // r11
    ulong user_rip;     // rcx
    ulong r9, r8, r10, rdx, rsi, rdi;
    ulong num;          // rax
}

enum Syscall : ulong {
    Klog      = 0,
    ExitThread  = 1,
    Open      = 2,
    Close     = 3,
    Read      = 4,
    Write     = 5,
    Stat      = 6,
    Readdir   = 7,
    Mkdir     = 8,
    Unlink    = 9,
    Seek      = 10,
    Dup       = 11,
    Rename    = 12,
    Truncate  = 13,
    Chdir     = 14,
    Getcwd    = 15,
}

extern(C) ulong syscall_dispatch( SyscallFrame* frame ) {
    ktrace!"syscall: num=%d rdi=%x rsi=%x rdx=%x r10=%x r8=%x r9=%x\n"(frame.num, frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9);

    switch (frame.num) {
        case Syscall.Klog:
            return sys_klog(frame.rdi, frame.rsi);

        case Syscall.ExitThread:
            return sys_exit_thread( cast(Status)frame.rdi );

        default:
            return cast(Status)Status.Inval;
    }
}

Status
sys_exit_thread( Status code ) {
    import kern.thread;

    ktrace!"sys_exit_thread: code=%d\n"(code);
    thread_exit(code);
    return Status.Ok; // never reached
}

// SYS_KLOG: write string to serial (arg1=ptr, arg2=len)
//
// Copies the user buffer page-by-page through the HHDM so we never
// dereference a user virtual address from kernel mode.
Status
sys_klog( ulong ptr, ulong len ) {
    import hal.cpu;
    import mm.pfdb;

    enum MAX_KLOG_LEN = 256;

    if (len == 0 || len > MAX_KLOG_LEN)
        return Status.Inval;

    // Reject kernel-space pointers (canonical hole starts at 0x0000_8000...)
    if (ptr >= 0x0000_8000_0000_0000)
        return Status.Inval;

    // Overflow wrap check
    if (ptr + len < ptr)
        return Status.Inval;

    // Copy page-by-page via HHDM
    char[MAX_KLOG_LEN] kbuf;
    copy_from_user(kbuf.ptr, ptr, len);

    klog!"[user] %s"(kbuf[0 .. len]);
    return Status.Ok;
}

void*
copy_from_user( void* dest, ulong src, ulong len ) {
    import hal.cpu;
    import mm.pfdb;

    // Reject kernel-space pointers (canonical hole starts at 0x0000_8000...)
    if (src >= 0x0000_8000_0000_0000)
        return null;

    // Overflow wrap check
    if (src + len < src)
        return null;

    // Copy page-by-page via HHDM
    ulong copied = 0;
    auto pml4 = read_cr3();

    while (copied < len) {
        auto uaddr    = src + copied;
        auto page_off = uaddr & (PAGE_SIZE - 1);
        auto chunk    = len - copied;
        auto avail    = PAGE_SIZE - page_off;
        if (chunk > avail)
            chunk = avail;

        // Walk the current address space — returns page-aligned phys addr, or -1.
        auto pa = v2p(pml4, uaddr);
        if (pa == cast(ulong)-1)
            return null;

        auto src_ptr = cast(const(char)*) p2v(pa + page_off);
        auto dst_ptr = cast(char*) dest + copied;
        dst_ptr[0 .. chunk] = src_ptr[0 .. chunk];
        copied += chunk;
    }
    return dest;
}
