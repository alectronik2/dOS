module kern.object;

import kern.thread, kern.timer;

enum WaitType {
    All,
    Any
}

enum KObjectType {
    Thread,
    Event,
    Timer,
    Mutex,
    Semaphore,
    File,
    Socket,
    IoMux,
    FileMap,
}

class KObject {
    KObjectType type;
    bool signaled;

    u16 handle_count;
    u16 lock_count;

    WaitBlock *waitlist_head;
    WaitBlock *waitlist_tail;
}

struct WaitBlock {
    KObject object;
    Thread thread;

    WaitType waittype;
    Status   waitkey;

    WaitBlock *next;

    WaitBlock *next_wait;
    WaitBlock *prev_wait;

    //
    // Remove thread wait block from wait list for object 
    //
    void
    remove_from_waitlist() {
        if( next_wait ) next_wait.prev_wait = prev_wait;
        if( prev_wait ) prev_wait.next_wait = next_wait;
        if( &this == object.waitlist_head ) object.waitlist_head = next_wait;
        if( &this == object.waitlist_tail ) object.waitlist_tail = prev_wait;

    }
}

class IOObject : KObject {

}

class Mutex : KObject {
    Thread  owner;
    i32     recursion;
}

class Event : KObject {
    int     manual_reset;
}

class Semaphore : KObject {
    int     count;
}

class WaitableTimer : KObject {
    Timer timer;
}

//
// Insert thread wait block in wait list for object
//
private void
insert_in_waitlist( KObject obj, WaitBlock *wb ) {
    wb.next_wait = null;
    wb.prev_wait = obj.waitlist_tail;
    if( obj.waitlist_tail ) obj.waitlist_tail.next_wait = wb;
    obj.waitlist_tail = wb;
    if( !obj.waitlist_head ) obj.waitlist_head = wb;
}

//
// Remove thread wait block from wait list for object
//
private void
remove_from_waitlist( WaitBlock *wb ) {
    if( wb.next_wait ) wb.next_wait.prev_wait = wb.prev_wait;
    if( wb.prev_wait ) wb.prev_wait.next_wait = wb.next_wait;
    if( wb == wb.object.waitlist_head ) wb.object.waitlist_head = wb.next_wait;
    if( wb == wb.object.waitlist_tail ) wb.object.waitlist_tail = wb.prev_wait;
}

//
// Test if thread is ready to run, i.e. all wait all objects on the waiting list are signaled or one waitany 
// object is signaled. This routine also sets the waitkey for the thread from the waitblock.
//
bool
thread_ready_to_run( Thread t ) {
    auto any = false;
    auto all = true;
    
    auto wb = t.waitlist;
    while( wb ) {
        if( wb.waittype == WaitType.Any ) {
            if( wb.object.signaled ) {
                any = true;
                t.waitkey = wb.waitkey;
            }
        } else {
            if( !wb.object.signaled ) {
                all = false;
            } else {
                t.waitkey = wb.waitkey;
            }
        }

        wb = wb.next;
    }

    return any || all;
}

//
// Remove thread from all wait blocks
//
void
cancel_wait( Thread t ) {
    auto wb = t.waitlist;
    while( wb ) {
        wb.remove_from_waitlist();
        wb = wb.next;
    }

    t.waitlist = null;
}

//
// Release thread and mark it as ready to run
//
void
release_thread( Thread t ) {
    cancel_wait( t );
    mark_thread_ready( t, 1, 1 );
}

//
// Release all threads waiting for object
//
void
release_waiters( KObject o, Status waitkey ) {
    auto wb = o.waitlist_head;

    while( wb ) {
        auto next = wb.next_wait;
        if( thread_ready_to_run(wb.thread) ) {
            wb.thread.waitkey = waitkey;
            release_thread( wb.thread );
        }
        wb = next;
    }
}

//
// Called when an object waits on a siagnaled object.
//
Status
enter_object( KObject obj ) {
    Status rc = Status.Ok;

    switch( obj.type ) {
        case KObjectType.Thread:
            // Set thread exit code as wait key
            rc = (cast(Thread)obj).exitcode;
            break;

        case KObjectType.Event:
            if( !(cast(Event)obj).manual_reset ) obj.signaled = false;
            break;

        case KObjectType.Mutex:
            // Set state to nonsignaled and set current thread as owner
            auto m = cast(Mutex)obj;
            m.signaled = false;
            m.owner = current_thread();
            m.recursion = 1;
            break;

        case KObjectType.Semaphore:
            // Decrease count and set to nonsignaled if count reaches zero
            if( --((cast(Semaphore)obj).count) == 0 ) obj.signaled = false;
            break;

        case KObjectType.IoMux:
            // TODO
            break;

        default:
    }

    return Status.Ok;
}

Status
wait_for_object( KObject obj, uint timeout ) {
    return wait_for_one_object( obj, timeout, false );
}

Status
wait_for_one_object( KObject obj, ulong timeout, bool alertable ) {
    auto t = current_thread();
    WaitBlock wb;

    // If object is signaled we do not have to wait
    if( obj.signaled ) return enter_object( obj );

    if( obj.type == KObjectType.Mutex && (cast(Mutex)obj).owner == t ) {
        // Mutex is already owned by current thread, increase recursion count
        (cast(Mutex)obj).recursion++;
        return Status.Ok;
    }

    if( !timeout )
        return Status.TimeOut;

    t.waitlist = &wb;
    wb.thread = t;
    wb.object = obj;
    wb.waittype = WaitType.Any;
    wb.waitkey = Status.Ok;
    wb.next = null;

    insert_in_waitlist( obj, &wb );

    if( timeout == INFINITE ) {
        if( alertable ) {
            auto rc = enter_alertable_wait( WaitReason.Object );
            if( rc < 0 ) {
                cancel_wait( t );
                t.waitkey = rc;
            }
        } else {
            enter_wait( WaitReason.Object );
        }

        return t.waitkey;
    } else {
        auto timer = new WaitableTimer();
        WaitBlock wbtmo;
        // TODO
    }

    return Status.Ok;
}