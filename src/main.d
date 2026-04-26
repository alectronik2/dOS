module main;

static import hal.limine;
import hal.serial, hal.cpu, lib.klog, hal.gdt, hal.idt;
import mm.pfdb, mm.heap, kern.fb, hal.pit, hal.pic;
import kern.timer, hal.kbd, kern.thread, kern.process;
import kern.dbg, kern.ipc, kern.handle;
import hal.pci, vfs.vfs;

mixin(hal.limine.BaseRevision!("1"));

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

    klog!"Hello world!\n";

    if (mixin(hal.limine.BaseRevisionSupported!()) == false) hang();
    if (framebufferReq.response == null||
        framebufferReq.response.framebufferCount < 1) hang();

    gdt_init();
    ktrace!"GDT set up.\n";
    idt_init();
    ktrace!"IDT set up.\n";

    auto framebuffer = framebufferReq.response.framebuffers[0];
    foreach (ulong i; 0..100) {
        uint* fbPtr = cast(uint*)framebuffer.address;
        fbPtr[i * (framebuffer.pitch / 4) + i] = 0xffffff;
    }

    klog!"Memmap: %i entries at 0x%x\n"(memmapReq.response.entryCount, memmapReq.response.entries);

    if( moduleReq.response != null ) {
        klog!"Modules: %i\n"(moduleReq.response.moduleCount);
        for( auto i = 0, mod = moduleReq.response.modules[0]; i < moduleReq.response.moduleCount; i++, mod++ ) {
            klog!" # -> Path %s, Cmdline %s @ 0x%x\n"(mod.path, mod.cmdline, mod.address);
        }
    }

    fb_init( framebuffer );

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

    handles_init();
    ipc_init();
    vfs_init();

    //import lib.str;
    //string_test();

    klog!"<Green>Enabling interrupts ...</>\n";
    enable_interrupts();

    //pciInit();
    //pciDumpDevices();

    klog!"<Blue>Initialization complete.</> Idling.\n";
    for (;;) {
        if( has_ready_threads() )
            dispatch();
        asm { hlt; }
    }
}
