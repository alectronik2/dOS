.section .text
.global gdt_flush
gdt_flush:
    lgdt (%rdi)
    mov  $0x10, %ax
    mov  %ax, %ds
    mov  %ax, %es
    mov  %ax, %fs
    mov  %ax, %gs
    mov  %ax, %ss
    /* Reload CS via far return: push new CS, push return RIP, lretq. */
    pushq $0x08
    lea  1f(%rip), %rax
    pushq %rax
    lretq
1:  ret

.global tss_flush
tss_flush:
    mov  %di, %ax
    ltr  %ax
    ret
