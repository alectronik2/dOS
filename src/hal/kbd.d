module hal.kbd;

import hal.cpu, hal.pic, hal.idt, lib.klog;

const KBD_DATA_PORT      = 0x60;
const KBD_STATUS_PORT    = 0x64;      // read  → status
const KBD_CMD_PORT       = 0x64;      // write → command

const KBD_STATUS_OUTPUT_FULL = 0x01;  // data waiting in output buffer
const KBD_STATUS_INPUT_FULL  = 0x02;  // controller still processing

const PIC1_DATA          = 0x21;

__gshared Interrupt kbd_intr;

// Key codes for non-printable keys (above ASCII range)
enum KeyCode : ubyte {
    None      = 0,
    Escape    = 0x80,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Insert, Delete, Home, End, PageUp, PageDown,
    ArrowUp, ArrowDown, ArrowLeft, ArrowRight,
    CapsLock, NumLock, ScrollLock,
    LShift, RShift, LCtrl, RCtrl, LAlt, RAlt,
    LSuper, RSuper,
    PrintScreen, Pause,
}

// Modifier bitmask
enum Modifier : ubyte {
    None     = 0x00,
    LShift   = 0x01,
    RShift   = 0x02,
    LCtrl    = 0x04,
    RCtrl    = 0x08,
    LAlt     = 0x10,
    RAlt     = 0x20,
    CapsLock = 0x40,
    NumLock  = 0x80,
}

struct KeyEvent {
    ubyte   scancode;   // raw scancode
    ubyte   keycode;    // ASCII or KeyCode enum value
    ubyte   modifiers;  // Modifier bitmask
    bool    released;   // true = key-up
    bool    printable;  // true = keycode is a printable ASCII char
}

// Scancode set 1, unshifted
private immutable ubyte[128] scancodeToAscii = [
/*00*/ 0,
/*01*/ KeyCode.Escape,
/*02*/ '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=',
/*0e*/ '\b',
/*0f*/ '\t',
/*10*/ 'q','w','e','r','t','y','u','i','o','p','[',']',
/*1c*/ '\n',
/*1d*/ KeyCode.LCtrl,
/*1e*/ 'a','s','d','f','g','h','j','k','l',';','\'','`',
/*2a*/ KeyCode.LShift,
/*2b*/ '\\',
/*2c*/ 'z','x','c','v','b','n','m',',','.','/',
/*36*/ KeyCode.RShift,
/*37*/ '*',           // keypad *
/*38*/ KeyCode.LAlt,
/*39*/ ' ',
/*3a*/ KeyCode.CapsLock,
/*3b*/ KeyCode.F1, KeyCode.F2, KeyCode.F3, KeyCode.F4,
       KeyCode.F5, KeyCode.F6, KeyCode.F7, KeyCode.F8,
       KeyCode.F9, KeyCode.F10,
/*45*/ KeyCode.NumLock,
/*46*/ KeyCode.ScrollLock,
/*47*/ '7','8','9','-','4','5','6','+','1','2','3','0','.',
/*54..7f — largely unused in set 1 */ 0,0,0,
/*57*/ KeyCode.F11,
/*58*/ KeyCode.F12,
       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
       0,0,0,0,0,0,0,
];

// Scancode set 1, shifted
private immutable ubyte[128] scancodeToAsciiShift = [
/*00*/ 0,
/*01*/ KeyCode.Escape,
/*02*/ '!','@','#','$','%','^','&','*','(',')','_','+',
/*0e*/ '\b',
/*0f*/ '\t',
/*10*/ 'Q','W','E','R','T','Y','U','I','O','P','{','}',
/*1c*/ '\n',
/*1d*/ KeyCode.LCtrl,
/*1e*/ 'A','S','D','F','G','H','J','K','L',':','"','~',
/*2a*/ KeyCode.LShift,
/*2b*/ '|',
/*2c*/ 'Z','X','C','V','B','N','M','<','>','?',
/*36*/ KeyCode.RShift,
/*37*/ '*',
/*38*/ KeyCode.LAlt,
/*39*/ ' ',
/*3a*/ KeyCode.CapsLock,
/*3b*/ KeyCode.F1, KeyCode.F2, KeyCode.F3, KeyCode.F4,
       KeyCode.F5, KeyCode.F6, KeyCode.F7, KeyCode.F8,
       KeyCode.F9, KeyCode.F10,
/*45*/ KeyCode.NumLock,
/*46*/ KeyCode.ScrollLock,
/*47*/ '7','8','9','-','4','5','6','+','1','2','3','0','.',
       0,0,0,
/*57*/ KeyCode.F11,
/*58*/ KeyCode.F12,
       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
       0,0,0,0,0,0,0,
];

const KBD_BUF_SIZE = 64;

private __gshared {
    KeyEvent[KBD_BUF_SIZE] kbdBuffer;
    size_t kbdHead = 0;  // producer (ISR writes)
    size_t kbdTail = 0;  // consumer (kbdRead* writes)

    ubyte  kbdModifiers   = 0;
    bool   kbdE0Prefix    = false;  // extended scancode prefix
    bool   kbdInitialized = false;
}

private void
kbd_wait_input() {
    // Spin until input buffer is empty (controller ready to accept)
    size_t timeout = 100_000;
    while ((inb(KBD_STATUS_PORT) & KBD_STATUS_INPUT_FULL) && --timeout)
        asm { nop; }
}

private void
kbd_wait_output() {
    size_t timeout = 100_000;
    while (!(inb(KBD_STATUS_PORT) & KBD_STATUS_OUTPUT_FULL) && --timeout)
        asm { nop; }
}

void
kbd_set_leds( bool scroll, bool num, bool caps ) {
    ubyte mask = cast(ubyte)((scroll ? 0x01 : 0) |
                             (num    ? 0x02 : 0) |
                             (caps   ? 0x04 : 0));
    kbd_wait_input();
    outb( KBD_DATA_PORT, 0xED );   // LED command
    kbd_wait_output();
    inb( KBD_DATA_PORT );          // consume ACK (0xFA)
    kbd_wait_input();
    outb( KBD_DATA_PORT, mask );
    kbd_wait_output();
    inb( KBD_DATA_PORT );          // consume ACK
}

/** Returns true if at least one KeyEvent is waiting. */
bool
kbd_event_available() {
    return kbdHead != kbdTail;
}

/**
 * kbdReadEvent — dequeue the oldest KeyEvent.
 * Returns false if the buffer is empty.
 */
bool
kbd_read_event( out KeyEvent ev ) {
    if (kbdHead == kbdTail)
        return false;
    ev = kbdBuffer[kbdTail];
    kbdTail = (kbdTail + 1) & (KBD_BUF_SIZE - 1);
    return true;
}


Status
kbd_handler( void* arg ) {
    auto sc = inb( KBD_DATA_PORT );

    // Extended scancode prefix
    if (sc == 0xE0) {
        kbdE0Prefix = true;
        return Status.Ok;
    }

    bool released  = (sc & 0x80) != 0;
    ubyte make     = sc & 0x7F;

    KeyEvent ev;
    ev.scancode  = sc;
    ev.released  = released;
    ev.modifiers = kbdModifiers;

    bool shifted = (kbdModifiers & (Modifier.LShift | Modifier.RShift)) != 0;
    bool capsOn  = (kbdModifiers & Modifier.CapsLock) != 0;

    if (kbdE0Prefix) {
        kbdE0Prefix = false;
        ev.keycode  = decodeExtended(make, released);
        ev.printable = false;
    } else {
        if (make < 128) {
            ubyte raw = shifted ? scancodeToAsciiShift[make]
                                : scancodeToAscii[make];

            // CapsLock flips case of letters only
            if (capsOn && raw >= 'a' && raw <= 'z')
                raw = cast(ubyte)(raw - 32);
            else if (capsOn && raw >= 'A' && raw <= 'Z')
                raw = cast(ubyte)(raw + 32);

            ev.keycode   = raw;
            ev.printable = (raw >= 0x20 && raw < 0x80) &&
                            raw != KeyCode.LShift &&
                            raw != KeyCode.RShift &&
                            raw != KeyCode.LCtrl  &&
                            raw != KeyCode.RCtrl  &&
                            raw != KeyCode.LAlt   &&
                            raw != KeyCode.RAlt   &&
                            raw != KeyCode.CapsLock;
        }
    }

    updateModifiers(ev.keycode, released);
    ev.modifiers = kbdModifiers;   // update after modifier state change

    // Enqueue (drop on overflow — ISR must never block)
    size_t next = (kbdHead + 1) & (KBD_BUF_SIZE - 1);
    if (next != kbdTail) {
        kbdBuffer[kbdHead] = ev;
        kbdHead = next;
    }


    KeyEvent k;
    kbd_read_event( k );

    if( !k.released && k.printable )
        klog!"[kbd] got %c\n"(k.keycode);

    return Status.Ok;
}

// ──────────────────────────────────────────────────────────────────────────────
// Extended (0xE0-prefixed) scancode decoding
// ──────────────────────────────────────────────────────────────────────────────
private ubyte
decodeExtended(ubyte make, bool released) @nogc nothrow {
    switch (make) {
        case 0x48: return KeyCode.ArrowUp;
        case 0x50: return KeyCode.ArrowDown;
        case 0x4B: return KeyCode.ArrowLeft;
        case 0x4D: return KeyCode.ArrowRight;
        case 0x47: return KeyCode.Home;
        case 0x4F: return KeyCode.End;
        case 0x49: return KeyCode.PageUp;
        case 0x51: return KeyCode.PageDown;
        case 0x52: return KeyCode.Insert;
        case 0x53: return KeyCode.Delete;
        case 0x1D: return KeyCode.RCtrl;
        case 0x38: return KeyCode.RAlt;
        case 0x5B: return KeyCode.LSuper;
        case 0x5C: return KeyCode.RSuper;
        default:   return 0;
    }
}


// ──────────────────────────────────────────────────────────────────────────────
// Modifier state machine
// ──────────────────────────────────────────────────────────────────────────────
private void
updateModifiers(ubyte kc, bool released) @nogc nothrow {
    // Toggle locks on make only
    if (!released) {
        if (kc == KeyCode.CapsLock) {
            kbdModifiers ^= Modifier.CapsLock;
            bool caps = (kbdModifiers & Modifier.CapsLock) != 0;
            // Update LED asynchronously-safe: only if not in ISR hot path
            // kbdSetLEDs(false, false, caps);  // uncomment if safe from ISR
            return;
        }
        if (kc == KeyCode.NumLock) {
            kbdModifiers ^= Modifier.NumLock;
            return;
        }
    }

    void setMod(ubyte bit, bool on) {
        if (on) kbdModifiers |= bit;
        else    kbdModifiers &= ~bit;
    }

    switch (kc) {
        case KeyCode.LShift:  setMod(Modifier.LShift, !released); break;
        case KeyCode.RShift:  setMod(Modifier.RShift, !released); break;
        case KeyCode.LCtrl:   setMod(Modifier.LCtrl,  !released); break;
        case KeyCode.RCtrl:   setMod(Modifier.RCtrl,  !released); break;
        case KeyCode.LAlt:    setMod(Modifier.LAlt,   !released); break;
        case KeyCode.RAlt:    setMod(Modifier.RAlt,   !released); break;
        default: break;
    }
}


void
kbd_init() {
    kbd_intr.register( 33, &kbd_handler );

    while( inb(KBD_STATUS_PORT) & 0x01 )
        inb( KBD_DATA_PORT );

    enable_irq( 1 );
}
