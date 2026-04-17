module lib.lock;

enum {
    SPINLOCK_UNLOCKED = 0,
    SPINLOCK_LOCKED   = 1,
}

struct SpinLock {
    private uint locked = 0;
    private ulong flags;

    void
    acquire() {
        ulong flags;
        
        asm {
            pushfq;
            pop flags;
            cli;
        }

        while( atomic_swap(&locked, SPINLOCK_LOCKED) ) {
            asm { nop; }
        }

        this.flags = flags;
    }

    bool
    try_acquire() {
        ulong flags;

        asm {
            pushfq;
            pop flags;
            cli;
        }

        if( atomic_swap(&locked, SPINLOCK_LOCKED) == SPINLOCK_UNLOCKED ) {
            this.flags = flags;
            return true;
        }

        asm {
            push flags;
            popfq;
        }
        return false;
    }

    void
    release() {
        auto flags = this.flags;
        locked = 0;

        asm {
            push flags;
            popfq;
        }
    }
}

private uint
atomic_swap( uint *ptr, uint val ) {
    uint old = val;

    asm {
        mov EAX, old;
        mov RCX, ptr;
        lock; xchg [RCX], EAX;
        mov old, EAX;
    }
    return old;
}