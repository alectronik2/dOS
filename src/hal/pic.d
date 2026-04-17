module hal.pic;

import lib.print;
import hal.cpu;

const PIC1_CMD          = 0x20;
const PIC1_DATA     = 0x21;

const PIC2_CMD          = 0xA0;
const PIC2_DATA      = 0xA1;

const PIC_MSTR_ICW1     = 0x11;
const PIC_MSTR_ICW2     = 0x20;
const PIC_MSTR_ICW3     = 0x04;
const PIC_MSTR_ICW4     = 0x01;

const PIC_SLV_ICW1      = 0x11;
const PIC_SLV_ICW2      = 0x28;
const PIC_SLV_ICW3      = 0x02;
const PIC_SLV_ICW4      = 0x01;

const PIC_EOI_BASE      = 0x60;

const PIC_EOI_CAS       = 0x62;
const PIC_EOI_FD        = 0x66;

__gshared uint irq_mask = 0xFFFB;

private void
set_intr_mask( uint mask ) {
    outb( PIC1_DATA, cast(ubyte)mask );
    outb( PIC2_DATA, cast(ubyte)(mask >> 8) );
}

private void
pic_remap( ubyte offset1, ubyte offset2 ) {
    /* Save existing interrupt masks. */
    ubyte m1 = inb(PIC1_DATA);
    ubyte m2 = inb(PIC2_DATA);

    /* ICW1: start initialisation sequence (cascade mode, ICW4 needed). */
    outb(PIC1_CMD,  0x11); io_wait();
    outb(PIC2_CMD,  0x11); io_wait();

    /* ICW2: base interrupt vectors. */
    outb(PIC1_DATA, offset1); io_wait();
    outb(PIC2_DATA, offset2); io_wait();
    
    /* ICW3: tell master there is a slave at IRQ2; tell slave its cascade id. */
    outb(PIC1_DATA, 0x04); io_wait();
    outb(PIC2_DATA, 0x02); io_wait();

    /* ICW4: 8086/88 mode. */
    outb(PIC1_DATA, 0x01); io_wait();
    outb(PIC2_DATA, 0x01); io_wait();

    /* Restore masks. */
    outb(PIC1_DATA, m1);
    outb(PIC2_DATA, m2);
}

void
enable_irq( ulong irq ) {
    irq_mask &= ~(1 << irq);
    if (irq >= 8) irq_mask &= ~(1 << 2);
    set_intr_mask( irq_mask );
}

void
disable_irq( ulong irq ) {
    irq_mask |= (1 << irq);
    if ((irq_mask & 0xFF00) == 0xFF00) irq_mask |= (1 << 2);
    set_intr_mask( irq_mask );
}

void
pic_eoi( ulong irq ) {
    if( irq >= 8 )
        outb( PIC2_CMD, 0x20 );
    outb( PIC1_CMD, 0x20 );
}

void
pic_init() {
    outb( PIC1_CMD, PIC_MSTR_ICW1 );
    outb( PIC2_CMD, PIC_SLV_ICW1 );
    outb( PIC1_DATA, PIC_MSTR_ICW2 );
    outb( PIC2_DATA, PIC_SLV_ICW2 );
    outb( PIC1_DATA, PIC_MSTR_ICW3 );
    outb( PIC2_DATA, PIC_SLV_ICW3 );
    outb( PIC1_DATA, PIC_MSTR_ICW4 );
    outb( PIC2_DATA, PIC_SLV_ICW4 );

    pic_remap( 0x20, 0x28 );

    set_intr_mask( irq_mask );    
}
