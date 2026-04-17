module hal.main;

import hal.cpu, lib.print, hal.gdt, hal.idt, lib.runtime;
import hal.serial, hal.bootboot, hal.pic, hal.pit;
import mm.pfdb, mm.heap, hal.kbd, kern.thread;
import lib.lock, kern.timer, lib.print, lib.runtime;

extern(C) void
kmain() {
    if( cpuid_current_cpu() != bootboot.bspid )
        hang();

    serial_write( "Kernel booting!\n" );

    fb_init( bootboot.fb_scanline, bootboot.fb_width, bootboot.fb_height, 32 );
    kprintf( "{WHITE}Kernel booting...{/}\n" );

    gdt_init();
    serial_write( "GDT initialized.\n" );
    idt_init();
    serial_write( "IDT initialized.\n" );

    pfdb_init();
    heap_init();

    kprintf( "Preparing interrupts ... " );
    pic_init();
    kprintf( "{GREEN}PIC{/} " );
    pit_init();
    kprintf( "{GREEN}PIT{/}\n" );
    
    kbd_init();

    percpu_init();
    timers_init();
    thread_init();

    enable_interrupts();
    kprintf( "{GREEN}Initialization complete. Hanging.\n" );

    hang();
}
