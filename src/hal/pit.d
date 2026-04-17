module hal.pit;

import lib.print, hal.idt, hal.pic;
import hal.cpu, kern.timer, kern.thread;

const TMR_CTRL = 0x43;
const TMR_CNT0 = 0x40;
const TMR_BOTH = 0x30;
const TMR_CH0 = 0x00;
const TMR_MD3 = 0x6;

const PIT_CLOCK = 1_193_180;
const TIMER_FREQ = 100;

const CLOCKS_PER_SEC = 1000;
const CLOCKS_PER_TICK = CLOCKS_PER_SEC / TIMER_FREQ;
const TICKS_PER_SEC = TIMER_FREQ;

const USECS_PER_TICK = 1_000_000 / TIMER_FREQ;
const MSECS_PER_TICK = 1000 / TIMER_FREQ;

struct timeval {
    ulong sec;
    ulong usec;
}

__gshared {
    Interrupt intr;

    ulong ticks = 0;
    ulong clocks = 0;

    timeval systemclock;
}

Status
timer_handler( void *arg ) {
    // update timer ticks and clocks
    clocks += CLOCKS_PER_TICK;
    ticks += 1;

    // update system clock
    systemclock.usec += USECS_PER_TICK;
    while( systemclock.usec >= 1_000_000 ) {
        systemclock.sec++;
        systemclock.usec -= 1_000_000;
    }

    run_timer_list();

    return Status.Ok;
}

void
pit_init() {
    uint cnt = PIT_CLOCK / TIMER_FREQ;
    outb( TMR_CTRL, TMR_CH0 + TMR_BOTH + TMR_MD3 );
    outb( TMR_CNT0, cast(ubyte)(cnt & 0xFF) );
    outb( TMR_CNT0, cast(ubyte)(cnt >> 8) );

    intr.register( 0x20, &timer_handler, null );
    enable_irq( 0 );
}
