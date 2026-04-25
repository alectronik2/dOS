module kern.handle;

import mm.heap, lib.klog, lib.lock, kern.object;

// ─────────────────────────────────────────────────────────────────────────────
// Handle encoding
//
//  63                16 15             0
//  ┌──────────────────┬────────────────┐
//  │   generation     │     index      │
//  └──────────────────┴────────────────┘
//   48 bits             16 bits → 65535 max slots
// ─────────────────────────────────────────────────────────────────────────────

alias Handle = ulong;

enum Handle INVALID_HANDLE = ulong.max;

private enum uint  INDEX_BITS  = 16;
private enum ulong INDEX_MASK  = (1UL << INDEX_BITS) - 1;   // 0xFFFF
private enum uint  GEN_SHIFT   = INDEX_BITS;
private enum uint  MAX_SLOTS   = INDEX_MASK;                 // 65535 sentinel

private Handle encodeHandle(ulong gen, uint idx) pure nothrow @nogc {
    return (gen << GEN_SHIFT) | idx;
}
// ─────────────────────────────────────────────────────────────────────────────
// Slot — union keeps free-list next out of the pointer field
// ─────────────────────────────────────────────────────────────────────────────

private struct Slot {
    ulong   gen;
    union {
        KObject obj;        // live
        uint    nextFree;   // free — index of next free slot
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// HandleTable
// ─────────────────────────────────────────────────────────────────────────────

class HandleTable : KObject {
    private SpinLock lock;
    private Slot[]   slots;
    private uint     freeHead;
    private uint     liveCount;

    this(uint capacity = 256) {
        assert(capacity > 0 && capacity < MAX_SLOTS);

        auto raw = kmalloc!void(capacity * Slot.sizeof);
        assert(raw, "HandleTable: allocation failed");

        slots     = (cast(Slot*) raw)[0 .. capacity];
        liveCount = 0;

        // Build free list: 0 → 1 → 2 → … → capacity-1 → MAX_SLOTS (sentinel)
        foreach (i; 0 .. capacity - 1)
            slots[i].nextFree = i + 1;
        slots[capacity - 1].nextFree = MAX_SLOTS;
        freeHead = 0;
    }

    ~this() {
        assert(liveCount == 0, "HandleTable: destroyed with live handles");
        kfree(slots.ptr);
        slots = null;
    }

    // ── Core operations ──────────────────────────────────────────────────────

    // Allocate a handle for obj.  Returns INVALID_HANDLE if the table is full.
    Handle alloc(KObject obj) {
        if (!obj) return INVALID_HANDLE;

        lock.lock();
        scope(exit) lock.unlock();

        if (freeHead >= slots.length) return INVALID_HANDLE;

        uint  idx = freeHead;
        Slot* s   = &slots[idx];

        freeHead  = s.nextFree;
        s.gen++;
        s.obj     = obj;
        liveCount++;

        return encodeHandle(s.gen, idx);
    }

    // Look up a handle.  Returns null if stale, closed, or out of range.
    KObject get(Handle h) {
        if (h == INVALID_HANDLE) return null;

        uint  idx = cast(uint)(h  & INDEX_MASK);
        ulong gen = h >> GEN_SHIFT;

        lock.lock();
        scope(exit) lock.unlock();

        if (idx >= slots.length) return null;

        Slot* s = &slots[idx];
        if (s.gen != gen || s.obj is null) return null;

        return s.obj;
    }

    // Type-safe lookup — returns null if stale or wrong type.
    T getTyped(T : KObject)(Handle h) {
        return cast(T) get(h);
    }

    // Close a handle.  Does not free the underlying object.
    bool close(Handle h) {
        uint  idx = cast(uint)(h  & INDEX_MASK);
        ulong gen = h >> GEN_SHIFT;

        lock.lock();
        scope(exit) lock.unlock();

        if (idx >= slots.length) return false;

        Slot* s = &slots[idx];
        if (s.gen != gen || s.obj is null) return false;

        s.gen++;
        s.obj      = null;
        s.nextFree = freeHead;
        freeHead   = idx;
        liveCount--;

        return true;
    }

    // Close a handle and free the underlying KObject in one step.
    bool closeAndFree(Handle h) {
        KObject obj = get(h);
        if (!obj) return false;
        close(h);
        kdestroy(obj);
        return true;
    }

    // Replace the object behind an existing valid handle.
    // Useful for handle duplication / object upgrade patterns.
    bool replace(Handle h, KObject newObj) {
        if (!newObj) return false;

        uint  idx = cast(uint)(h  & INDEX_MASK);
        ulong gen = h >> GEN_SHIFT;

        lock.lock();
        scope(exit) lock.unlock();

        if (idx >= slots.length) return false;

        Slot* s = &slots[idx];
        if (s.gen != gen || s.obj is null) return false;

        s.obj = newObj;
        return true;
    }

    // ── Iteration ────────────────────────────────────────────────────────────

    // Call visitor(handle, obj) for every live slot.
    // Visitor must be nothrow @nogc.  Table is locked for the duration.
    void forEach(scope void delegate(Handle, KObject) nothrow @nogc visitor) {
        lock.lock();
        scope(exit) lock.unlock();

        for (uint idx = 0; idx < cast(uint) slots.length; idx++) {
            Slot* s = &slots[idx];
            if (s.obj is null) continue;
            visitor(encodeHandle(s.gen, idx), s.obj);
        }
    }

    // ── Diagnostics ──────────────────────────────────────────────────────────

    uint count()    const { return liveCount; }
    uint capacity() const { return cast(uint) slots.length; }
    bool full()     const { return freeHead >= slots.length; }
    bool empty()    const { return liveCount == 0; }

    // KObject vtable stubs — a HandleTable is itself a KObject so it can be
    // stored in a parent table (process → handle table handle).
    void wait()   { assert(false, "HandleTable: wait() not meaningful"); }
    void signal() { assert(false, "HandleTable: signal() not meaningful"); }
}

class Test : KObject {
    int x;
}

__gshared HandleTable htsb;

void
handles_init() {
    htsb = new HandleTable();
    assert(htsb, "HandleTable: initialization failed");

    auto h1 = htsb.alloc( new Test() );
    auto h2 = htsb.alloc( new Test() );

    auto o1 = htsb.getTyped!Test(h1);
    auto o2 = htsb.getTyped!Test(h2);

    klog!"HandleTable test: h1=%x o1=%x h2=%x o2=%x\n"(
        cast(ulong)h1, cast(ulong)cast(void*)o1,
        cast(ulong)h2, cast(ulong)cast(void*)o2
    );

}
