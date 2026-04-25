module hal.serial;

import hal.cpu;
import lib.klog;

const COM1_PORT = 0x3F8;

public void
serial_init() {
    outb(COM1_PORT + 1, 0x00);    // Disable all interrupts
    outb(COM1_PORT + 3, 0x80);    // Enable DLAB (set baud rate divisor)
    outb(COM1_PORT + 0, 0x03);    // Set divisor to 3 (lo byte) 38400 baud
    outb(COM1_PORT + 1, 0x00);    //                  (hi byte)
    outb(COM1_PORT + 3, 0x03);    // 8 bits, no parity, one stop bit
    outb(COM1_PORT + 2, 0xC7);    // Enable FIFO, clear them, with 14-byte threshold
    outb(COM1_PORT + 4, 0x0B);    // IRQs enabled, RTS/DSR set
    outb(COM1_PORT + 4, 0x1E);    // Set in loopback mode, test the serial chip
    outb(COM1_PORT + 0, 0xAE);    // Test serial chip (send byte 0xAE and check if serial returns same byte)

    // Check if serial is faulty (i.e., not same byte)
    if (inb(COM1_PORT + 0) != 0xAE) {
        // Serial port is faulty
        kpanic!"Serial port initialization failed: serial port is faulty.";
    }

    outb(COM1_PORT + 4, 0x0F);    // Set normal operation mode
}

public bool
serial_is_transmit_empty() {
    return (inb(COM1_PORT + 5) & 0x20) != 0;
}

public void
serial_write_char( char c ) {
    while (!serial_is_transmit_empty()) {}
    outb(COM1_PORT, cast(u8)c);
}

public void
serial_write( string s ) {
    foreach (c; s) {
        serial_write_char(c);
    }
}

public void
serial_write( const(char)* s, uint len ) {
    for( auto i = 0; i < len; i++ ) {
        serial_write_char(s[i]);
    }
}

public void
serial_write_hex( ulong value ) {
    char[16] buf = void;
    size_t n = 0;

    do {
        auto digit = cast(u8)(value & 0xF);
        buf[n++] = cast(char)(digit < 10 ? ('0' + digit) : ('a' + digit - 10));
        value >>= 4;
    } while (value);

    serial_write("0x");
    while (n > 0) {
        serial_write_char(buf[--n]);
    }
}
