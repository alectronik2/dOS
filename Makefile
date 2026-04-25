DC      := ldc2
AS      := as
LD      := ld.lld
GRUB    := grub-mkrescue
QEMU    := qemu-system-x86_64

KERNEL  := iso_root/kernel.elf
ISO     := os.iso


#   -relocation-model=static  no GOT/PLT — all references are PC-relative
#                             or absolute within the image
DFLAGS  := \
    -mtriple=x86_64-unknown-elf \
    -relocation-model=static \
    --code-model=kernel \
    -disable-red-zone \
    -disable-loop-vectorization \
    -disable-slp-vectorization \
    -mattr=-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2 \
	-O2 \
    -Isrc \
	-frame-pointer=all

ASFLAGS := --64

# --no-dynamic-linker     no PT_INTERP program header
LDFLAGS := \
    -T src/linker.ld \
    -z noexecstack \
    --no-dynamic-linker \
    -m elf_x86_64

# ---------------------------------------------------------------------------
# Sources → objects
# ---------------------------------------------------------------------------
DSRCS   := src/hal/cpu.d src/hal/serial.d src/lib/klog.d src/lib/lock.d \
		   src/main.d src/mm/heap.d src/lib/runtime.d src/hal/limine.d \
		   src/hal/gdt.d src/hal/idt.d src/hal/pic.d src/mm/pfdb.d \
		   src/mm/aspace.d src/kern/fb.d src/kern/timer.d src/hal/pit.d \
		   src/kern/thread.d src/kern/object.d src/hal/kbd.d src/kern/process.d \
		   src/kern/sync.d src/kern/syscall.d src/kern/handle.d src/kern/ipc.d
SSRCS   := src/hal/asm.S

DOBJS   := $(DSRCS:src/%.d=build/%.o) build/object.o
SOBJS   := $(SSRCS:src/%.S=build/%.o)
OBJS    := $(SOBJS) $(DOBJS)
DDEPS   := $(DOBJS:.o=.d)

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
.PHONY: all iso run clean

all: $(KERNEL)

-include $(DDEPS)

$(KERNEL): $(OBJS) build/font.o src/linker.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS) build/font.o
	@rm -f System.map*
	@echo "  LINKED  $@"

build/font.o: various/font.psf
	$(LD) -m elf_x86_64  -r -b binary -o $@ $<

build/%.o: src/%.d | build
	@mkdir -p $(dir $@)
	@$(DC) $(DFLAGS) --makedeps=$(basename $@).d -c -of=$@ $<
	@echo "  DC      $<"

build/%.o: %.d | build
	@mkdir -p $(dir $@)
	@$(DC) $(DFLAGS) --makedeps=$(basename $@).d -c -of=$@ $<
	@echo "  DC      $<"

build/%.o: src/%.S | build
	@$(AS) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

build:
	@mkdir -p build/hal
	@mkdir -p build/kern
	@mkdir -p build/lib
	@mkdir -p build/mm

# ---------------------------------------------------------------------------
# Bootable ISO via GRUB
# ---------------------------------------------------------------------------
iso: $(KERNEL)
	@mkdir -p iso_root/EFI/BOOT
	@cp various/limine/limine-bios.sys various/limine/limine-bios-cd.bin iso_root/
	@xorriso -as mkisofs -b limine-bios-cd.bin -no-emul-boot -boot-load-size 4 \
			 -boot-info-table --protective-msdos-label \
			iso_root -o $(ISO)
	@./various/limine/limine bios-install $(ISO)
	@echo "  XORRISO $(ISO)"

# ---------------------------------------------------------------------------
# Run in QEMU (requires 'make iso' first)
# ---------------------------------------------------------------------------
run: iso
	@$(QEMU) \
	    -cdrom $(ISO) \
	    -m 4096 \
		-smp 4 \
	    -no-reboot \
		-serial stdio \
		-no-reboot \
	    -no-shutdown

# Run with both display window and serial output on stdout (debugging)
run-debug: iso
	@$(QEMU) \
	    -cdrom $(ISO) \
	    -m 32M \
	    -serial stdio \
	    -no-reboot \
	    -no-shutdown

# Run headless with serial output on stdout (useful for CI / scripting)
run-serial: iso
	@$(QEMU) \
	    -cdrom $(ISO) \
	    -m 32M \
	    -nographic \
	    -serial mon:stdio \
	    -no-reboot \
	    -no-shutdown

clean:
	@rm -rf build $(KERNEL) $(IMG)
