module kern.sync;

import kern.object, kern.thread, lib.klog, lib.lock;

struct WaitEntry {
    Thread    thread;
    WaitEntry* next;
}

struct WaitQueue {
    WaitEntry* head;
    WaitEntry* tail;

    void enqueue(WaitEntry* e) {
        e.next = null;
        if (!tail) { head = tail = e; return; }
        tail.next = e;
        tail      = e;
    }

    // Returns the dequeued entry, or null if empty.
    WaitEntry* dequeue() {
        if (!head) return null;
        WaitEntry* e = head;
        head = head.next;
        if (!head) tail = null;
        return e;
    }

    bool empty() const { return head is null; }
}

// Helper — block current thread, enqueue entry, drop lock, yield.
// The lock must be held on entry; it is released before scheduleNext().
void parkOn(ref SpinLock lk, ref WaitQueue q)  {
    auto      self  = current_thread();
    WaitEntry entry = { thread: self };
    q.enqueue(&entry);
    self.block();
    lk.unlock();
    dispatch();   // returns here when rescheduled
}

// ─────────────────────────────────────────────────────────────────────────────
// Mutex — non-recursive, priority-ordered wait queue
// ─────────────────────────────────────────────────────────────────────────────

class Mutex {
    SpinLock   lock;
    Thread     owner;       // null when unlocked
    WaitQueue  waiters;

    this() {
        lock    = SpinLock.init;
        owner   = null;
        waiters = WaitQueue.init;
    }

    // Acquire — blocks calling thread if already held.
    // Must be called with interrupts disabled (or the spinlock handles it).
    void acquire() {
        lock.lock();

        auto self = current_thread();

        if (!owner) {
            // Fast path — uncontended
            owner = self;
            lock.unlock();
            return;
        }

        // Slow path — enqueue and yield
        WaitEntry entry = { thread: self };
        waiters.enqueue(&entry);
        lock.unlock();

        // Block until woken by release()
        self.block();      // sets thread state to Blocked
        dispatch();        // yields CPU; returns when rescheduled
    }

    // Try to acquire without blocking.  Returns true on success.
    bool tryAcquire() {
        lock.lock();
        scope(exit) lock.unlock();

        if (owner) return false;
        owner = current_thread();
        return true;
    }

    // Release — must be called by the owning thread.
    void release() {
        lock.lock();

        assert(owner is current_thread(), "Mutex released by non-owner");

        WaitEntry* next = waiters.dequeue();
        if (!next) {
            owner = null;               // nobody waiting — just unlock
        } else {
            owner = next.thread;        // hand off directly to next waiter
            next.thread.unblock();      // make it runnable
        }

        lock.unlock();
    }
}


class Semaphore : KObject {
    KObject   base;
    SpinLock  lock;
    long      count;        // signed so over-release is detectable
    WaitQueue waiters;

    this() {
        lock      = SpinLock.init;
        count     = 0;
        waiters   = WaitQueue.init;
    }

    static void destroy(Semaphore s) {
        assert(s.waiters.empty, "Semaphore destroyed with waiters");
        kdestroy( s );
    }

    // Wait (P) — decrements count; blocks if count would go negative.
    void wait() {
        lock.lock();

        if (count > 0) {
            count--;
            lock.unlock();
            return;
        }

        // Must block
        auto       self  = current_thread();
        WaitEntry  entry = { thread: self };
        waiters.enqueue(&entry);
        lock.unlock();

        self.block();
        dispatch();
    }

    // Signal (V) — increments count; wakes one waiter if any.
    void signal(long n = 1) {
        lock.lock();

        while (n-- > 0) {
            WaitEntry* w = waiters.dequeue();
            if (w) {
                w.thread.unblock();     // count stays 0 — token goes to waiter
            } else {
                count++;
            }
        }

        lock.unlock();
    }

    // Returns current count without blocking.
    long peek() {
        lock.lock();
        scope(exit) lock.unlock();
        return count;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Event — manual-reset and auto-reset modes
// ─────────────────────────────────────────────────────────────────────────────

enum EventMode : ubyte {
    AutoReset,      // resets to unsignalled after waking one waiter
    ManualReset,    // stays signalled until explicitly reset; wakes all waiters
}

class Event {
    SpinLock  lock;
    bool      signalled;
    EventMode mode;
    WaitQueue waiters;

    this( EventMode mode = EventMode.AutoReset, bool initialState = false ) {
        lock      = SpinLock.init;
        signalled = false;
        mode      = EventMode.AutoReset;
        waiters   = WaitQueue.init;
    }

    // Wait — returns immediately if already signalled, else blocks.
    void
    wait() {
        lock.lock();

        if (signalled) {
            if (mode == EventMode.AutoReset) signalled = false;
            lock.unlock();
            return;
        }

        auto  self  = current_thread();
        WaitEntry entry = { thread: self };
        waiters.enqueue(&entry);
        lock.unlock();

        self.block();
        dispatch();
    }

    // Set — signal the event.
    //   ManualReset: wakes all current waiters, stays signalled.
    //   AutoReset:   wakes exactly one waiter (or stays signalled if none).
    void set() {
        lock.lock();

        if (mode == EventMode.ManualReset) {
            signalled = true;
            // Drain the queue — all waiters become runnable.
            WaitEntry* w;
            while ((w = waiters.dequeue()) !is null)
                w.thread.unblock();
        } else {
            WaitEntry* w = waiters.dequeue();
            if (w) {
                // Hand token directly to waiter; don't set signalled.
                w.thread.unblock();
            } else {
                signalled = true;   // no waiter — remember for next wait()
            }
        }

        lock.unlock();
    }

    // Reset — manually clear the signalled state (mainly for ManualReset events).
    void reset() {
        lock.lock();
        signalled = false;
        lock.unlock();
    }

    // Pulse — set then immediately reset (wake waiters but don't stay signalled).
    // Inherently racy for ManualReset; use with care.
    void pulse() {
        lock.lock();

        WaitEntry* w;
        if (mode == EventMode.ManualReset) {
            while ((w = waiters.dequeue()) !is null)
                w.thread.unblock();
        } else {
            if ((w = waiters.dequeue()) !is null)
                w.thread.unblock();
        }
        // signalled stays false

        lock.unlock();
    }
}

class ReadWriteLock : KObject {
    private SpinLock  lock;
    private uint      readers;      // active reader count
    private bool      writerHeld;   // true while a writer owns the lock
    private WaitQueue readWaiters;  // readers blocked by a pending/active writer
    private WaitQueue writeWaiters; // writers queued behind each other

    // KObject dispatch: wait = read-acquire, signal = read-release
    void wait()   { acquireRead(); }
    void signal() { releaseRead(); }

    // ── Reader side ──────────────────────────────────────────────────────────

    void acquireRead() {
        lock.lock();
        // Block if a writer holds or is waiting (writer priority).
        if (!writerHeld && writeWaiters.empty) {
            readers++;
            lock.unlock();
            return;
        }
        parkOn(lock, readWaiters);  // released inside; re-check on wake omitted
        // parkOn returns rescheduled — writer granted us the read slot by
        // incrementing readers before calling unblock() (see releaseWrite).
    }

    bool tryAcquireRead() {
        lock.lock();
        scope(exit) lock.unlock();
        if (writerHeld || !writeWaiters.empty) return false;
        readers++;
        return true;
    }

    void releaseRead() {
        lock.lock();
        assert(readers > 0, "RWLock: releaseRead with no active readers");
        readers--;
        if (readers == 0) {
            // Last reader out — wake one pending writer if any.
            auto w = writeWaiters.dequeue();
            if (w) {
                writerHeld = true;
                w.thread.unblock();
            }
        }
        lock.unlock();
    }

    // ── Writer side ──────────────────────────────────────────────────────────

    void acquireWrite() {
        lock.lock();
        if (!writerHeld && readers == 0) {
            writerHeld = true;
            lock.unlock();
            return;
        }
        parkOn(lock, writeWaiters);
        // Woken by releaseRead (last reader) or releaseWrite (writer handoff).
        // writerHeld already set to true by the waker before unblock().
    }

    bool tryAcquireWrite() {
        lock.lock();
        scope(exit) lock.unlock();
        if (writerHeld || readers > 0) return false;
        writerHeld = true;
        return true;
    }

    void releaseWrite() {
        lock.lock();
        assert(writerHeld, "RWLock: releaseWrite without holding write lock");

        // Prefer waking a waiting writer first (writer priority).
        auto w = writeWaiters.dequeue();
        if (w) {
            // writerHeld stays true — hand off directly.
            w.thread.unblock();
            lock.unlock();
            return;
        }

        // No writers — wake all pending readers.
        writerHeld = false;
        WaitEntry* r;
        while ((r = readWaiters.dequeue()) !is null) {
            readers++;              // grant the slot before waking
            r.thread.unblock();
        }
        lock.unlock();
    }

    // ── RAII guards ──────────────────────────────────────────────────────────

    auto readLock()  { return ReadGuard(this); }
    auto writeLock() { return WriteGuard(this); }

    struct ReadGuard {
        private ReadWriteLock rw;
        @disable this();
        this(ReadWriteLock rw) { this.rw = rw; rw.acquireRead(); }
        ~this()                { rw.releaseRead(); }
        @disable this(this);   // non-copyable
    }

    struct WriteGuard {
        private ReadWriteLock rw;
        @disable this();
        this(ReadWriteLock rw) { this.rw = rw; rw.acquireWrite(); }
        ~this()                { rw.releaseWrite(); }
        @disable this(this);
    }
}
