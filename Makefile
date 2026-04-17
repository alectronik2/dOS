DC      := ldc2
AS      := as
LD      := ld
GRUB    := grub-mkrescue
QEMU    := qemu-system-x86_64

KERNEL  := kernel.elf
IMG     := os.img


#   -relocation-model=static  no GOT/PLT — all references are PC-relative
#                             or absolute within the image
DFLAGS  := \
    -mtriple=x86_64-unknown-elf \
    -relocation-model=static \
    --code-model=kernel \
    -disable-red-zone \
    -O1 \
    -disable-loop-vectorization \
    -disable-slp-vectorization \
    -mattr=-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2 \
    -I . \
    -I src \
	-frame-pointer=all

ASFLAGS := --64

# --no-dynamic-linker     no PT_INTERP program header
LDFLAGS := \
    -T linker.ld \
    -z noexecstack \
    --no-dynamic-linker

# ---------------------------------------------------------------------------
# Sources → objects
# ---------------------------------------------------------------------------
DSRCS   := src/hal/main.d src/hal/bootboot.d src/lib/print.d \
		   src/lib/runtime.d src/hal/cpu.d src/mm/heap.d src/hal/serial.d \
		   src/hal/gdt.d src/hal/idt.d src/hal/pic.d src/mm/pfdb.d \
		   src/mm/aspace.d src/lib/lock.d src/hal/pit.d src/kern/timer.d \
		   src/hal/kbd.d src/kern/thread.d src/kern/object.d \
		   src/kern/dbg.d
SSRCS   := src/hal/asm.S

DOBJS   := $(DSRCS:src/%.d=build/%.o) build/object.o
SOBJS   := $(SSRCS:src/%.S=build/%.o)
OBJS    := $(SOBJS) $(DOBJS) 

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
.PHONY: all iso run clean

all: $(KERNEL)

$(KERNEL): $(OBJS) linker.ld
	@$(LD) -r -b binary -o build/font.o font.psf
	@$(LD) $(LDFLAGS) -o $@ $(OBJS) build/font.o
	@echo "  LINKED  $@"

build/%.o: src/%.d | build
	@$(DC) $(DFLAGS) -c -of=$@ $<
	@echo "  DC      $<"

build/%.o: %.d | build
	@$(DC) $(DFLAGS) -c -of=$@ $<
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
img: $(KERNEL)
	@cp $(KERNEL) disk_root/
	@mkbootimg disk_root/mkbootimg.json os.img
	@echo "  IMG     $(IMG)"

# ---------------------------------------------------------------------------
# Run in QEMU (requires 'make iso' first)
# ---------------------------------------------------------------------------
run: img
	@$(QEMU) \
	    -hda $(IMG) \
	    -m 4096 \
		-smp 4 \
	    -no-reboot \
		-serial stdio \
		-no-reboot \
	    -no-shutdown

# Run with both display window and serial output on stdout (debugging)
run-debug: img
	@$(QEMU) \
	    -cdrom $(ISO) \
	    -m 32M \
	    -serial stdio \
	    -no-reboot \
	    -no-shutdown

# Run headless with serial output on stdout (useful for CI / scripting)
run-serial: img
	@$(QEMU) \
	    -cdrom $(ISO) \
	    -m 32M \
	    -nographic \
	    -serial mon:stdio \
	    -no-reboot \
	    -no-shutdown

clean:
	@rm -rf build $(KERNEL) $(IMG)
