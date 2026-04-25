module kern.timer;

import lib.klog, hal.pit;

const TVN_BITS = 6;
const TVR_BITS = 8;
const TVN_SIZE = (1 << TVN_BITS);
const TVR_SIZE = (1 << TVR_BITS);
const TVN_MASK = (TVN_SIZE - 1);
const TVR_MASK = (TVR_SIZE - 1);

struct TimerLink {
    TimerLink* next;
    TimerLink* prev;
}

struct TimerVec {
    int index;
    TimerLink[TVR_SIZE] vec;
}

private void
cascade_timers( TimerVec *tv ) {
    auto head = &tv.vec[tv.index];
    auto curr = head.next;

    while( curr != head ) {
        auto timer = cast(Timer*)curr;
        auto next = curr.next;

        timer.attach();
        curr = next;
    }

    head.next = head.prev = head;
    tv.index = (tv.index + 1) & TVN_MASK;
}

alias TimerProc = void function( void* );

struct Timer {
    TimerLink link;
    ulong     expires;
    int       active;
    TimerProc handler;
    void*     arg;

    this( TimerProc handler, void *arg ) {
        this.handler = handler;
        this.arg     = arg;
    }

    void
    add() {
        if( active ) {
            klog!"timer: timer is already active\n";
            return;
        }

        attach();
    }

    bool
    del() {
        auto rc = detach();

        link.next = null;
        link.prev = null;

        return rc;
    }

    bool
    mod( ulong expires ) {
        this.expires = expires;
        auto rc = detach();
        attach();

        return rc;
    }

    private void
    attach() {
        auto expires = this.expires;
        auto idx     = expires - timer_ticks;
        TimerLink *vec;

        if( idx < TVR_SIZE ) {
            auto i = expires & TVR_MASK;
            vec = &tv1.vec[i];
        } else if( idx < 1 << (TVR_BITS + TVN_BITS) ) {
            auto i = (expires >> TVR_BITS) & TVN_MASK;
            vec = &tv2.vec[i];
        } else if( idx < 1 << (TVR_BITS + 2 * TVN_BITS) ) {
            auto i = (expires >> (TVR_BITS + TVN_BITS)) & TVN_MASK;
            vec = &tv3.vec[i];
        } else if( idx < 1 << (TVR_BITS + 3 * TVN_BITS) ) {
            auto i = (expires >> (TVR_BITS + 2 * TVN_BITS)) & TVN_MASK;
            vec = &tv4.vec[i];
        } else if( cast(long)idx < 0 ) {
            // Can happen if you add a timer with expires == timer_ticks,
            // or you set a timer to go off in the past
            vec = &tv1.vec[tv1.index];
        } else {
            auto i = (expires >> (TVR_BITS + 3 * TVN_BITS)) & TVN_MASK;
            vec = &tv5.vec[i];
        }

        link.next = vec;
        link.prev = vec.prev;
        vec.prev.next = cast(TimerLink *)&this;
        vec.prev = cast(TimerLink *)&this;

        active = true;
    }

    private bool
    detach() {
        if( !active ) return false;

        link.next.prev = link.prev;
        link.prev.next = link.next;
        active = false;

        return true;
    }
}

private __gshared {
    ulong timer_ticks = 0;

    TimerVec tv5, tv4, tv3, tv2;
    TimerVec tv1;

    TimerVec*[5] tvecs = [ &tv1, &tv2, &tv3, &tv4, &tv5 ];
}


private auto noof_tvecs() => tvecs.sizeof / tvecs[0].sizeof;

void
run_timer_list() {
    while( (long)(ticks - timer_ticks) > 0) {
        TimerLink* head, curr;

        if( !tv1.index ) {
            auto n = 1;
            do {
                cascade_timers( tvecs[n] );
            } while( tvecs[n].index == 1 && ++n < noof_tvecs() );
        }

        while( true ) {
            Timer *timer;
            TimerProc handler;
            void* arg;

            head = &tv1.vec[tv1.index];
            curr = head.next;
            if( curr == head ) break;

            timer = cast(Timer*)curr;
            handler = timer.handler;
            arg = timer.arg;

            timer.detach();
            timer.link.next = timer.link.prev = null;

            klog!"Firing timer 0x{x}"(timer);

            handler( arg );
        }

        timer_ticks++;
        tv1.index = (tv1.index + 1) & TVR_MASK;
    }
}

void
timers_init() {
    klog!"Initializing timer subsystem: %i vectors ... "(noof_tvecs());

    for( auto i = 0; i < TVN_SIZE; i++ ) {
        tv5.vec[i].next = tv5.vec[i].prev = &tv5.vec[i];
        tv4.vec[i].next = tv4.vec[i].prev = &tv4.vec[i];
        tv3.vec[i].next = tv3.vec[i].prev = &tv3.vec[i];
        tv2.vec[i].next = tv2.vec[i].prev = &tv2.vec[i];
    }

    for( auto i = 0; i < TVR_SIZE; i++ ) {
        tv1.vec[i].next = tv1.vec[i].prev = &tv1.vec[i];
    }

    klogf!( "<Green>done</>\n" );
}
