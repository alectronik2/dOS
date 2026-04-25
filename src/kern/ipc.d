// ipc.d — message-passing IPC built on KObject
module kern.ipc;

import mm.heap, kern.object, kern.handle, kern.sync, kern.thread;
import lib.lock, kern.sync, lib.klog, kern.process, kern.handle;
import kern.handle;

// ─────────────────────────────────────────────────────────────────────────────
// Message
// ─────────────────────────────────────────────────────────────────────────────

enum MsgType : uint {
    Data   = 0,   // raw byte payload
    Handle = 1,   // handle transfer (moves a Handle across channel endpoints)
    Error  = 2,   // error reply
}

struct Message {
    MsgType  type;
    uint     len;       // payload bytes used
    ulong    tag;       // caller-defined correlation id

    union {
        ubyte[128] data;    // inline payload — fits most small kernel messages
        Handle     handle;  // for MsgType.Handle transfers
    }

    // Convenience constructors
    static Message fromData(ulong tag, const(ubyte)[] payload)  {
        assert(payload.length <= 128, "IPC: payload exceeds inline buffer");
        Message m;
        m.type = MsgType.Data;
        m.tag  = tag;
        m.len  = cast(uint) payload.length;
        m.data[0 .. payload.length] = payload[];
        return m;
    }

    static Message fromHandle(ulong tag, Handle h)  {
        Message m;
        m.type   = MsgType.Handle;
        m.tag    = tag;
        m.handle = h;
        m.len    = Handle.sizeof;
        return m;
    }

    static Message error(ulong tag, uint code)  {
        Message m;
        m.type = MsgType.Error;
        m.tag  = tag;
        m.len  = uint.sizeof;
        (cast(uint*) m.data.ptr)[0] = code;
        return m;
    }

    uint errorCode() const  {
        assert(type == MsgType.Error);
        return (cast(uint*) data.ptr)[0];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MessageNode — intrusive queue node, stack-allocated by sender
// ─────────────────────────────────────────────────────────────────────────────

private struct MessageNode {
    Message      msg;
    MessageNode* next;
    Thread       sender;    // non-null for synchronous send — woken on reply
}

private struct MessageQueue {

    MessageNode* head;
    MessageNode* tail;
    uint         count;

    void enqueue(MessageNode* n) {
        n.next = null;
        if (!tail) { head = tail = n; }
        else       { tail.next = n; tail = n; }
        count++;
    }

    MessageNode* dequeue() {
        if (!head) return null;
        auto n = head;
        head   = head.next;
        if (!head) tail = null;
        count--;
        return n;
    }

    bool empty() const { return head is null; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel — bidirectional, two endpoints (client / server)
//
//  Client                          Server
//  ──────                          ──────
//  send()  ──── msgQueue ────►  receive()
//  recv()  ◄─── replyQueue ──── reply()
//
// ─────────────────────────────────────────────────────────────────────────────

class Channel : KObject {

    private SpinLock     lock;
    private MessageQueue msgQueue;      // client → server
    private MessageQueue replyQueue;   // server → client
    private WaitQueue    msgWaiters;   // threads blocked in receive()
    private WaitQueue    replyWaiters; // threads blocked in sendSync()
    private bool         closed;

    // ── Async send (fire and forget) ─────────────────────────────────────────

    bool send(ref Message msg) {
        lock.lock();
        if (closed) { lock.unlock(); return false; }

        MessageNode* n = kmalloc!MessageNode();
        if (!n) { lock.unlock(); return false; }
        n.msg    = msg;
        n.sender = null;

        msgQueue.enqueue(n);

        // Wake one receiver if any are waiting
        auto w = msgWaiters.dequeue();
        if (w) w.thread.unblock();

        lock.unlock();
        return true;
    }

    // ── Synchronous send — blocks until server calls reply() ─────────────────

    bool sendSync(ref Message msg, ref Message replyOut) {
        lock.lock();
        if (closed) { lock.unlock(); return false; }

        // Stack-allocate node — safe because we block here until reply arrives
        MessageNode node;
        node.msg    = msg;
        node.sender = current_thread();

        msgQueue.enqueue(&node);

        auto w = msgWaiters.dequeue();
        if (w) w.thread.unblock();

        // Park until reply() wakes node.sender directly.  Do not enqueue this
        // synchronous sender in replyWaiters; that queue is for async replies.
        node.sender.block();
        lock.unlock();
        dispatch();

        // reply() wrote into node.msg before unblocking us
        replyOut = node.msg;
        return true;
    }

    // ── Receive — blocks until a message arrives ─────────────────────────────

    bool receive(ref Message msgOut, ref MessageNode* nodeOut) {
        lock.lock();

        while (msgQueue.empty) {
            if (closed) { lock.unlock(); return false; }
            parkOn(lock, msgWaiters);
        }

        nodeOut = msgQueue.dequeue();
        msgOut  = nodeOut.msg;
        lock.unlock();
        return true;
    }

    // Non-blocking receive — returns false immediately if queue is empty
    bool tryReceive(ref Message msgOut, ref MessageNode* nodeOut) {
        lock.lock();
        scope(exit) lock.unlock();

        if (msgQueue.empty || closed) return false;

        nodeOut = msgQueue.dequeue();
        msgOut  = nodeOut.msg;
        return true;
    }

    // ── Reply — answer a synchronous send ────────────────────────────────────

    void reply(MessageNode* node, ref Message replyMsg) {
        lock.lock();

        if (node.sender) {
            // Synchronous — write reply into the node and wake sender.
            // The node lives on the sender's stack so it's still valid.
            node.msg = replyMsg;
            node.sender.unblock();
            // Remove from replyWaiters — sender will consume node.msg on wake
        } else {
            // Async send — push reply onto replyQueue for an explicit recv
            MessageNode* n = kmalloc!MessageNode();
            if (n) {
                n.msg    = replyMsg;
                n.sender = null;
                replyQueue.enqueue(n);
                auto w = replyWaiters.dequeue();
                if (w) w.thread.unblock();
            }
        }

        // Free node only if it was heap-allocated (async path)
        if (!node.sender) kfree(node);

        lock.unlock();
    }

    // Receive a reply (async send path)
    bool receiveReply(ref Message replyOut) {
        lock.lock();

        while (replyQueue.empty) {
            if (closed) { lock.unlock(); return false; }
            parkOn(lock, replyWaiters);
        }

        auto n   = replyQueue.dequeue();
        replyOut = n.msg;
        kfree(n);
        lock.unlock();
        return true;
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    void close() {
        lock.lock();
        closed = true;

        // Wake all waiters so they observe closed == true and return false
        WaitEntry* w;
        while ((w = msgWaiters.dequeue())   !is null) w.thread.unblock();
        while ((w = replyWaiters.dequeue()) !is null) w.thread.unblock();

        // Drain heap-allocated nodes
        MessageNode* n;
        while ((n = msgQueue.dequeue())   !is null) kfree(n);
        while ((n = replyQueue.dequeue()) !is null) kfree(n);

        lock.unlock();
    }

    void wait()   { Message m; MessageNode* n; receive(m, n); }
    void signal() { /* not meaningful for Channel */ }
}

// ─────────────────────────────────────────────────────────────────────────────
// Port — named rendezvous point; multiple senders, one receiver
//
// Senders connect() to get a Channel endpoint.
// The server calls accept() to get each inbound Channel.
// ─────────────────────────────────────────────────────────────────────────────

// Pending connection node — stack-allocated in connect()
private struct ConnectNode {
    Channel      channel;
    ConnectNode* next;
    Thread      connector;  // parked until accept() picks up the channel
}

private struct ConnectQueue {
    ConnectNode* head;
    ConnectNode* tail;

    void enqueue(ConnectNode* n) {
        n.next = null;
        if (!tail) { head = tail = n; }
        else       { tail.next = n; tail = n; }
    }

    ConnectNode* dequeue() {
        if (!head) return null;
        auto n = head;
        head   = head.next;
        if (!head) tail = null;
        return n;
    }

    bool empty() const { return head is null; }
}

class Port : KObject {

    private SpinLock    lock;
    private ConnectQueue pending;   // channels waiting for accept()
    private WaitQueue   acceptWaiters;
    private bool        closed;

    // ── Client side ──────────────────────────────────────────────────────────

    // Connect — creates a Channel and blocks until the server accept()s it.
    Channel connect() {
        auto ch = new Channel();
        auto t = current_thread();
        if (!ch) return null;

        lock.lock();
        if (closed) { lock.unlock(); kdestroy(ch); return null; }

        ConnectNode node;
        node.channel   = ch;
        node.connector = t;

        pending.enqueue(&node);

        // Wake a waiting accept()
        auto w = acceptWaiters.dequeue();
        if (w) w.thread.unblock();

        // Park until accept() takes our stack-allocated ConnectNode and wakes
        // this connector directly through node.connector.
        t.block();
        lock.unlock();
        dispatch();

        return ch;
    }

    // ── Server side ──────────────────────────────────────────────────────────

    // Accept — blocks until a client connect()s, returns the new Channel.
    Channel accept() {
        lock.lock();

        while (pending.empty) {
            if (closed) { lock.unlock(); return null; }
            parkOn(lock, acceptWaiters);
        }

        ConnectNode* node = pending.dequeue();
        Channel ch        = node.channel;

        // Wake the connector — it can now use the channel
        node.connector.unblock();

        lock.unlock();
        return ch;
    }

    void close() {
        lock.lock();
        closed = true;
        WaitEntry* w;
        while ((w = acceptWaiters.dequeue()) !is null) w.thread.unblock();
        // Wake pending connectors so they observe null
        ConnectNode* n;
        while ((n = pending.dequeue()) !is null) {
            n.connector.unblock();
        }
        lock.unlock();
    }

    void wait()   { accept(); }
    void signal() { }
}

// ===============================================================================

__gshared {
    Port port;
    Handle hPort;
}

Status
accept_thread( void *arg ) {
   // Accept loop
    while (true) {
        Channel ch = port.accept();
        if (!ch) break;   // port closed

        // Spawn a handler thread or handle inline:
        Message msg;
        MessageNode* node;
        while (ch.receive(msg, node)) {
            switch (msg.type) {
                case MsgType.Data:
                    // process msg.data[0 .. msg.len]
                    klog!"IPC server received data: tag=%x len=%d\n"(msg.tag, msg.len);
                    auto reply = Message.error(msg.tag, 0);   // OK
                    ch.reply(node, reply);
                    break;

                case MsgType.Handle:
                    // transfer handle into this process's table
                    Handle transferred = msg.handle;
                    klog!"IPC server received handle: tag=%x handle=%x\n"(msg.tag, transferred);
                    auto reply = Message.fromData(msg.tag, cast(ubyte[])"ack");
                    ch.reply(node, reply);
                    break;

                default: break;
            }
        }
    }

    return Status.Ok;
}

Status
server_thread( void *arg ) {
    Channel ch = port.connect();

    // Async send:
    auto m = Message.fromData(1, cast(ubyte[])"hello");
    ch.send(m);

    klog!"Message sent, waiting for reply...\n";

    Message rep;
    ch.receiveReply(rep);

    klog!"Received reply: type=%d tag=%x len=%d\n"(rep.type, rep.tag, rep.len);

    // Synchronous send — blocks until reply:
    auto req = Message.fromData(2, cast(ubyte[])"query");
    Message syncRep;
    ch.sendSync(req, syncRep);   // returns when server calls reply()
    klog!"Received sync reply: type=%d tag=%x len=%d\n"(syncRep.type, syncRep.tag, syncRep.len);

    // Handle transfer:
    auto hm = Message.fromHandle(3, hPort);
    ch.send(hm);
    ch.receiveReply(rep);
    klog!"Received handle reply: type=%d tag=%x len=%d\n"(rep.type, rep.tag, rep.len);

    // Teardown:
    ch.close();
    kdestroy(ch);
    port.close();
    //table.closeAndFree(hPort);
    return Status.Ok;
}

void
ipc_init() {
    klog!"IPC subsystem initialized\n";

    port = new Port();
    hPort = htsb.alloc(port);
    klog!"Port allocated\n";

    auto t = new Thread(kernel_process, &accept_thread, cast(void*)"IPC accept thread".ptr);
    auto t2 = new Thread(kernel_process, &server_thread, cast(void*)"IPC server thread".ptr);
}
