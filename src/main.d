module main;

static import hal.limine;
import hal.serial, hal.cpu, lib.klog, hal.gdt, hal.idt;
import mm.pfdb, mm.heap, kern.fb, hal.pit, hal.pic;
import kern.timer, hal.kbd, kern.thread, kern.process;
import kern.dbg, kern.vfs, kern.ipc, kern.handle;

mixin(hal.limine.BaseRevision!("1"));

private void
hcf() {
    for (;;) {
        asm { "hlt"; }
    }
}

__gshared hal.limine.StackSizeRequest stackSizeReq = {
    id: mixin(hal.limine.StackSizeRequestID!()),
    revision: 0,
    stackSize: 65536,
};

__gshared hal.limine.FramebufferRequest framebufferReq = {
    id: mixin(hal.limine.FramebufferRequestID!()),
    revision: 0
};

__gshared hal.limine.MemmapRequest memmapReq = {
    id: mixin(hal.limine.MemoryMapRequestID!()),
    revision: 0
};

__gshared hal.limine.ModuleRequest moduleReq = {
    id: mixin(hal.limine.ModuleRequestID!()),
    revision: 0
};

__gshared hal.limine.HHDMRequest hhdmReq = {
    id: mixin(hal.limine.HHDMRequestID!()),
    revision: 0
};

extern (C) void
kmain() {
    serial_init();
    logInit();

    if (mixin(hal.limine.BaseRevisionSupported!()) == false) {
        hcf();
    }

    if (framebufferReq.response == null
     || framebufferReq.response.framebufferCount < 1) {
        hcf();
    }

    auto framebuffer = framebufferReq.response.framebuffers[0];

    foreach (ulong i; 0..100) {
        uint* fbPtr = cast(uint*)framebuffer.address;
        fbPtr[i * (framebuffer.pitch / 4) + i] = 0xffffff;
    }

    klog!"Hello world!\n";
    klog!"Memmap: %i entries at 0x%x\n"(memmapReq.response.entryCount, memmapReq.response.entries);

    if( moduleReq.response != null ) {
        klog!"Modules: %i\n"(moduleReq.response.moduleCount);
        for( auto i = 0, mod = moduleReq.response.modules[0]; i < moduleReq.response.moduleCount; i++, mod++ ) {
            klog!" # -> Path %s, Cmdline %s @ 0x%x\n"(mod.path, mod.cmdline, mod.address);
        }
    }

    gdt_init();
    ktrace!"GDT set up.\n";
    idt_init();
    ktrace!"IDT set up.\n";

    //symmap_init();

    pfdb_init( memmapReq.response.entryCount, memmapReq.response.entries, hhdmReq.response.offset );
    klog!"Pageframe database set up.\n";

    heap_init();
    process_init();

    percpu_init();
    timers_init();

    thread_init();

    pic_init();
    pit_init();
    kbd_init();

    init_handles();
    ipc_init();
    //vfs_init();

    fb_init( framebuffer );

    klog!"<Green>Enabling interrupts ...</>\n";
    enable_interrupts();

    klog!"<Blue>Initialization complete.</> Hanging.\n";
    hcf();
}
