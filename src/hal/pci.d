module hal.pci;

/**
 * kernel.pci — PCI/PCIe configuration space driver
 *
 * Supports:
 *   - Legacy I/O port access  (CONFIG_ADDRESS 0xCF8 / CONFIG_DATA 0xCFC)
 *   - Enhanced Configuration Access Mechanism (ECAM / PCIe MMIO)
 *   - Full bus enumeration (bridges + functions)
 *   - BAR decoding (32-bit, 64-bit, I/O)
 *   - Capability list walking (MSI, MSI-X, PCIe, PM, …)
 *   - Device registry (static slab, up to MAX_PCI_DEVICES)
 */

import hal.cpu, lib.klog;

enum ushort PCI_CONFIG_ADDRESS = 0xCF8;
enum ushort PCI_CONFIG_DATA    = 0xCFC;

enum uint PCI_ENABLE_BIT       = 0x8000_0000;

enum ubyte PCI_MAX_BUS         = 255;
enum ubyte PCI_MAX_DEV         = 31;
enum ubyte PCI_MAX_FUNC        = 7;

// Standard header offsets
enum ubyte PCI_OFF_VENDOR      = 0x00;
enum ubyte PCI_OFF_DEVICE      = 0x02;
enum ubyte PCI_OFF_COMMAND     = 0x04;
enum ubyte PCI_OFF_STATUS      = 0x06;
enum ubyte PCI_OFF_REVISION    = 0x08;
enum ubyte PCI_OFF_PROG_IF     = 0x09;
enum ubyte PCI_OFF_SUBCLASS    = 0x0A;
enum ubyte PCI_OFF_CLASS       = 0x0B;
enum ubyte PCI_OFF_CACHE_LINE  = 0x0C;
enum ubyte PCI_OFF_LATENCY     = 0x0D;
enum ubyte PCI_OFF_HEADER_TYPE = 0x0E;
enum ubyte PCI_OFF_BIST        = 0x0F;
enum ubyte PCI_OFF_BAR0        = 0x10;   // through BAR5 = 0x24
enum ubyte PCI_OFF_SUBSYS_VEN  = 0x2C;
enum ubyte PCI_OFF_SUBSYS_ID   = 0x2E;
enum ubyte PCI_OFF_CAP_PTR     = 0x34;
enum ubyte PCI_OFF_INT_LINE    = 0x3C;
enum ubyte PCI_OFF_INT_PIN     = 0x3D;

// PCI-to-PCI bridge offsets (header type 0x01)
enum ubyte PCI_OFF_PRIMARY_BUS    = 0x18;
enum ubyte PCI_OFF_SECONDARY_BUS  = 0x19;
enum ubyte PCI_OFF_SUBORDINATE    = 0x1A;

// Status register bits
enum ushort PCI_STATUS_CAP_LIST   = 0x0010;

// Command register bits
enum ushort PCI_CMD_IO_SPACE      = 0x0001;
enum ushort PCI_CMD_MEM_SPACE     = 0x0002;
enum ushort PCI_CMD_BUS_MASTER    = 0x0004;
enum ushort PCI_CMD_INT_DISABLE   = 0x0400;

// Capability IDs
enum ubyte PCI_CAP_PM             = 0x01;
enum ubyte PCI_CAP_AGP            = 0x02;
enum ubyte PCI_CAP_MSI            = 0x05;
enum ubyte PCI_CAP_PCIX           = 0x07;
enum ubyte PCI_CAP_PCIE           = 0x10;
enum ubyte PCI_CAP_MSIX           = 0x11;

// BAR type bits
enum uint BAR_IO_SPACE            = 0x01;
enum uint BAR_MEM_TYPE_MASK       = 0x06;
enum uint BAR_MEM_TYPE_32         = 0x00;
enum uint BAR_MEM_TYPE_64         = 0x04;
enum uint BAR_MEM_PREFETCH        = 0x08;
enum uint BAR_ADDR_MASK_MEM       = 0xFFFF_FFF0;
enum uint BAR_ADDR_MASK_IO        = 0xFFFF_FFFC;

enum uint MAX_PCI_DEVICES         = 256;

// ─── public types ────────────────────────────────────────────────────────────

public:

/// Decoded Base Address Register
struct PciBar {
    ulong   address;    /// Physical base address (I/O or MMIO)
    ulong   size;       /// Region size in bytes (0 = not decoded yet)
    bool    isIo;       /// True = I/O port space, False = MMIO
    bool    is64bit;    /// True = 64-bit MMIO BAR
    bool    prefetch;   /// Prefetchable MMIO
    bool    valid;      /// False = BAR absent / not implemented
}

/// Compact PCI device descriptor stored in the registry
struct PciDevice {
    ubyte   bus;
    ubyte   dev;
    ubyte   func;
    ushort  vendorId;
    ushort  deviceId;
    ubyte   classCode;
    ubyte   subclass;
    ubyte   progIf;
    ubyte   revision;
    ubyte   headerType;   /// Low 7 bits only (bit 7 = multifunction)
    ubyte   intLine;
    ubyte   intPin;
    PciBar[6] bars;
    bool    valid;        /// Slot occupied in registry
}

// ─── ECAM state ──────────────────────────────────────────────────────────────

private:

/// ECAM (PCIe enhanced config) base, set by pciInitEcam()
__gshared ulong   g_ecamBase    = 0;
__gshared bool    g_ecamEnabled = false;

/// Device registry
__gshared PciDevice[MAX_PCI_DEVICES] g_devices;
__gshared uint g_deviceCount = 0;

// ─── config space address helpers ────────────────────────────────────────────

/// Build the 32-bit CONFIG_ADDRESS value for I/O port access (type-1)
pragma(inline, true)
private uint pciAddress(ubyte bus, ubyte dev, ubyte func, ubyte offset) pure {
    return PCI_ENABLE_BIT
         | (cast(uint)bus  << 16)
         | (cast(uint)dev  << 11)
         | (cast(uint)func <<  8)
         | (offset & 0xFC);
}

/// ECAM config space pointer: base + ((bus<<20)|(dev<<15)|(func<<12)|offset)
pragma(inline, true)
private ulong ecamAddress(ubyte bus, ubyte dev, ubyte func, ushort offset) {
    return g_ecamBase
         + (cast(ulong)bus  << 20)
         + (cast(ulong)dev  << 15)
         + (cast(ulong)func << 12)
         + offset;
}

// ─── raw config space read/write ─────────────────────────────────────────────

/// Read a 32-bit dword from PCI configuration space.
/// Uses ECAM if enabled, otherwise falls back to I/O port mechanism.
uint pciRead32(ubyte bus, ubyte dev, ubyte func, ubyte offset) {
    if (g_ecamEnabled) {
        auto addr = cast(uint*)ecamAddress(bus, dev, func, offset & 0xFC);
        // Volatile read via inline asm to prevent store-forwarding issues
        uint v;
        asm @nogc nothrow { "movl (%1), %0" : "=r"(v) : "r"(addr) : "memory"; }
        return v;
    }
    auto flags = save_interrupts();
    outl(PCI_CONFIG_ADDRESS, pciAddress(bus, dev, func, offset));
    auto v = inl(PCI_CONFIG_DATA);
    restore_interrupts(flags);
    return v;
}

/// Read a 16-bit word from PCI configuration space.
ushort pciRead16(ubyte bus, ubyte dev, ubyte func, ubyte offset) {
    uint dword = pciRead32(bus, dev, func, offset & 0xFC);
    return cast(ushort)(dword >> ((offset & 2) * 8));
}

/// Read an 8-bit byte from PCI configuration space.
ubyte pciRead8(ubyte bus, ubyte dev, ubyte func, ubyte offset) {
    uint dword = pciRead32(bus, dev, func, offset & 0xFC);
    return cast(ubyte)(dword >> ((offset & 3) * 8));
}

/// Write a 32-bit dword to PCI configuration space.
void pciWrite32(ubyte bus, ubyte dev, ubyte func, ubyte offset, uint val) {
    if (g_ecamEnabled) {
        auto addr = cast(uint*)ecamAddress(bus, dev, func, offset & 0xFC);
        asm @nogc nothrow { "movl %1, (%0)" :: "r"(addr), "r"(val) : "memory"; }
        return;
    }
    auto flags = save_interrupts();
    outl(PCI_CONFIG_ADDRESS, pciAddress(bus, dev, func, offset));
    outl(PCI_CONFIG_DATA, val);
    restore_interrupts(flags);
}

/// Write a 16-bit word to PCI configuration space (read-modify-write).
void pciWrite16(ubyte bus, ubyte dev, ubyte func, ubyte offset, ushort val) {
    uint shift = (offset & 2) * 8;
    uint mask  = 0xFFFF << shift;
    uint cur   = pciRead32(bus, dev, func, offset & 0xFC);
    pciWrite32(bus, dev, func, offset & 0xFC, (cur & ~mask) | (cast(uint)val << shift));
}

/// Write an 8-bit byte to PCI configuration space (read-modify-write).
void pciWrite8(ubyte bus, ubyte dev, ubyte func, ubyte offset, ubyte val) {
    uint shift = (offset & 3) * 8;
    uint mask  = 0xFF << shift;
    uint cur   = pciRead32(bus, dev, func, offset & 0xFC);
    pciWrite32(bus, dev, func, offset & 0xFC, (cur & ~mask) | (cast(uint)val << shift));
}

// ─── capability list ─────────────────────────────────────────────────────────

/// Walk the capability list.  Returns the config-space byte offset of the
/// first capability whose ID matches `capId`, or 0 if not found.
ubyte pciFindCap(ubyte bus, ubyte dev, ubyte func, ubyte capId) {
    ushort status = pciRead16(bus, dev, func, PCI_OFF_STATUS);
    if (!(status & PCI_STATUS_CAP_LIST))
        return 0;

    ubyte ptr = pciRead8(bus, dev, func, PCI_OFF_CAP_PTR) & 0xFC;
    uint  guard = 0;                       // loop guard (max 48 caps)
    while (ptr >= 0x40 && guard < 48) {
        ubyte id   = pciRead8(bus, dev, func, ptr);
        ubyte next = pciRead8(bus, dev, func, cast(ubyte)(ptr + 1)) & 0xFC;
        if (id == capId)
            return ptr;
        ptr = next;
        guard++;
    }
    return 0;
}

// ─── BAR decoding ────────────────────────────────────────────────────────────

/// Decode all BARs for a type-0 (endpoint) function.
/// Temporarily writes all-ones to measure the region size.
private void decodeBar(ubyte bus, ubyte dev, ubyte func,
                       ubyte barIdx, ref PciBar[6] bars)
{
    if (barIdx >= 6) return;

    ubyte offset = cast(ubyte)(PCI_OFF_BAR0 + barIdx * 4);
    uint  orig   = pciRead32(bus, dev, func, offset);

    PciBar bar;

    if (orig & BAR_IO_SPACE) {
        // --- I/O BAR ---
        bar.isIo = true;

        // Size probe
        pciWrite32(bus, dev, func, offset, 0xFFFF_FFFF);
        uint probe = pciRead32(bus, dev, func, offset);
        pciWrite32(bus, dev, func, offset, orig);

        probe &= BAR_ADDR_MASK_IO;
        if (probe == 0 || probe == BAR_ADDR_MASK_IO) {
            bar.valid = false;
            bars[barIdx] = bar;
            return;
        }
        bar.address = orig & BAR_ADDR_MASK_IO;
        bar.size    = cast(ulong)((~probe) + 1) & 0xFFFF;
        bar.valid   = true;
    } else {
        // --- MMIO BAR ---
        bar.isIo     = false;
        bar.prefetch = (orig & BAR_MEM_PREFETCH) != 0;

        uint type = orig & BAR_MEM_TYPE_MASK;

        if (type == BAR_MEM_TYPE_64) {
            // 64-bit BAR: uses this slot + next slot
            if (barIdx + 1 >= 6) { bar.valid = false; bars[barIdx] = bar; return; }
            bar.is64bit = true;

            ubyte offset2 = cast(ubyte)(offset + 4);
            uint  orig2   = pciRead32(bus, dev, func, offset2);

            // Size probe: write all-ones to both halves
            pciWrite32(bus, dev, func, offset,  0xFFFF_FFFF);
            pciWrite32(bus, dev, func, offset2, 0xFFFF_FFFF);
            uint probe_lo = pciRead32(bus, dev, func, offset);
            uint probe_hi = pciRead32(bus, dev, func, offset2);
            pciWrite32(bus, dev, func, offset,  orig);
            pciWrite32(bus, dev, func, offset2, orig2);

            ulong probe = (cast(ulong)probe_hi << 32) | (probe_lo & BAR_ADDR_MASK_MEM);
            if (probe == 0) { bar.valid = false; bars[barIdx] = bar; return; }

            bar.address = (cast(ulong)orig2 << 32) | (orig & BAR_ADDR_MASK_MEM);
            bar.size    = (~probe) + 1;
            bar.valid   = true;

            // Mark the upper-half slot as consumed
            bars[barIdx + 1].valid   = false;
            bars[barIdx + 1].is64bit = true;   // sentinel: upper half of 64-bit
        } else {
            // 32-bit BAR
            bar.is64bit = false;

            pciWrite32(bus, dev, func, offset, 0xFFFF_FFFF);
            uint probe = pciRead32(bus, dev, func, offset);
            pciWrite32(bus, dev, func, offset, orig);

            probe &= BAR_ADDR_MASK_MEM;
            if (probe == 0 || probe == BAR_ADDR_MASK_MEM) {
                bar.valid = false;
                bars[barIdx] = bar;
                return;
            }
            bar.address = orig & BAR_ADDR_MASK_MEM;
            bar.size    = cast(ulong)((~probe) + 1);
            bar.valid   = true;
        }
    }

    bars[barIdx] = bar;
}

// ─── enumeration ─────────────────────────────────────────────────────────────

private void scanFunction(ubyte bus, ubyte dev, ubyte func);
private void scanBus(ubyte bus);

/// Recursively scan a PCI-to-PCI bridge.
private void scanBridge(ubyte bus, ubyte dev, ubyte func) {
    ubyte secondary = pciRead8(bus, dev, func, PCI_OFF_SECONDARY_BUS);
    if (secondary != 0)
        scanBus(secondary);
}

/// Register a function in the device table.
private void registerDevice(ubyte bus, ubyte dev, ubyte func) {
    if (g_deviceCount >= MAX_PCI_DEVICES) return;

    PciDevice* d = &g_devices[g_deviceCount];
    d.bus        = bus;
    d.dev        = dev;
    d.func       = func;
    d.vendorId   = pciRead16(bus, dev, func, PCI_OFF_VENDOR);
    d.deviceId   = pciRead16(bus, dev, func, PCI_OFF_DEVICE);
    d.classCode  = pciRead8 (bus, dev, func, PCI_OFF_CLASS);
    d.subclass   = pciRead8 (bus, dev, func, PCI_OFF_SUBCLASS);
    d.progIf     = pciRead8 (bus, dev, func, PCI_OFF_PROG_IF);
    d.revision   = pciRead8 (bus, dev, func, PCI_OFF_REVISION);
    d.headerType = pciRead8 (bus, dev, func, PCI_OFF_HEADER_TYPE) & 0x7F;
    d.intLine    = pciRead8 (bus, dev, func, PCI_OFF_INT_LINE);
    d.intPin     = pciRead8 (bus, dev, func, PCI_OFF_INT_PIN);
    d.valid      = true;

    // Decode BARs only for endpoint devices (type 0)
    if (d.headerType == 0x00) {
        ubyte barIdx = 0;
        while (barIdx < 6) {
            decodeBar(bus, dev, func, barIdx, d.bars);
            // Skip the upper half of a 64-bit BAR
            if (d.bars[barIdx].valid && d.bars[barIdx].is64bit)
                barIdx += 2;
            else
                barIdx += 1;
        }
    }

    g_deviceCount++;
}

private void scanFunction(ubyte bus, ubyte dev, ubyte func) {
    ushort vendor = pciRead16(bus, dev, func, PCI_OFF_VENDOR);
    if (vendor == 0xFFFF) return;   // slot empty

    registerDevice(bus, dev, func);

    ubyte headerType = pciRead8(bus, dev, func, PCI_OFF_HEADER_TYPE) & 0x7F;
    if (headerType == 0x01) {
        // PCI-to-PCI bridge — recurse
        scanBridge(bus, dev, func);
    }
}

private void scanBus(ubyte bus) {
    for (ubyte dev = 0; dev <= PCI_MAX_DEV; dev++) {
        // Fast-path: skip if function 0 absent
        ushort vendor0 = pciRead16(bus, dev, 0, PCI_OFF_VENDOR);
        if (vendor0 == 0xFFFF) continue;

        // Check for multi-function device
        ubyte htype = pciRead8(bus, dev, 0, PCI_OFF_HEADER_TYPE);
        bool  multi = (htype & 0x80) != 0;

        scanFunction(bus, dev, 0);

        if (multi) {
            for (ubyte func = 1; func <= PCI_MAX_FUNC; func++)
                scanFunction(bus, dev, func);
        }
    }
}

// ─── public API ──────────────────────────────────────────────────────────────

public:

/**
 * Optional: supply the ECAM (PCIe MMIO config) base address from MCFG ACPI
 * table before calling pciInit().  If not called the driver falls back to
 * legacy I/O port access.
 *
 * Params:
 *   ecamBase = Physical address of the ECAM region (from MCFG entry).
 *              Must already be identity-mapped in the kernel page tables.
 */
void pciInitEcam(ulong ecamBase) {
    g_ecamBase    = ecamBase;
    g_ecamEnabled = true;
}

/**
 * Enumerate the entire PCI hierarchy starting from bus 0.
 * Call once during kernel init (after VMM is up if using ECAM).
 */
void pciInit() {
    auto flags = save_interrupts();
    g_deviceCount = 0;

    ktrace!"Scanning PCI buses ...\n";

    // Is host bridge itself multi-function?  If yes, each function is a
    // separate root bus.
    ubyte htype = pciRead8(0, 0, 0, PCI_OFF_HEADER_TYPE);
    if (htype & 0x80) {
        for (ubyte func = 0; func <= PCI_MAX_FUNC; func++) {
            if (pciRead16(0, 0, func, PCI_OFF_VENDOR) == 0xFFFF) continue;
            scanBus(func);   // func == bus number for host controllers
        }
    } else {
        scanBus(0);
    }
    restore_interrupts(flags);
}

/// Returns the number of PCI devices found during enumeration.
uint pciDeviceCount() { return g_deviceCount; }

/// Returns a pointer to the Nth device in the registry, or null if out of range.
PciDevice* pciGetDevice(uint index) {
    if (index >= g_deviceCount) return null;
    return &g_devices[index];
}

/**
 * Find a device by vendor + device ID.
 * Returns a pointer into the registry, or null if not present.
 * If `startAfter` is non-null, search continues after that entry (useful for
 * multiple instances of the same device class).
 */
PciDevice* pciFindDevice(ushort vendorId, ushort deviceId,
                         PciDevice* startAfter = null)
{
    bool skip = (startAfter !is null);
    for (uint i = 0; i < g_deviceCount; i++) {
        PciDevice* d = &g_devices[i];
        if (skip) {
            if (d is startAfter) skip = false;
            continue;
        }
        if (d.vendorId == vendorId && d.deviceId == deviceId)
            return d;
    }
    return null;
}

/**
 * Find a device by class/subclass (and optionally progIf).
 * Pass progIf = 0xFF to match any programming interface.
 */
PciDevice* pciFindClass(ubyte classCode, ubyte subclass, ubyte progIf = 0xFF,
                        PciDevice* startAfter = null)
{
    bool skip = (startAfter !is null);
    for (uint i = 0; i < g_deviceCount; i++) {
        PciDevice* d = &g_devices[i];
        if (skip) {
            if (d is startAfter) skip = false;
            continue;
        }
        if (d.classCode == classCode && d.subclass == subclass
            && (progIf == 0xFF || d.progIf == progIf))
            return d;
    }
    return null;
}

/**
 * Enable Memory Space, I/O Space, and/or Bus Mastering on a device.
 *
 * Params:
 *   d        = device (from registry)
 *   memSpace = enable MMIO decoding
 *   ioSpace  = enable I/O port decoding
 *   busMaster = enable DMA bus mastering
 *   disableIntx = disable legacy INTx# (set when using MSI/MSI-X)
 */
void pciEnableDevice(PciDevice* d,
                     bool memSpace  = true,
                     bool ioSpace   = false,
                     bool busMaster = true,
                     bool disableIntx = false)
{
    ushort cmd = pciRead16(d.bus, d.dev, d.func, PCI_OFF_COMMAND);
    if (memSpace)    cmd |= PCI_CMD_MEM_SPACE;
    if (ioSpace)     cmd |= PCI_CMD_IO_SPACE;
    if (busMaster)   cmd |= PCI_CMD_BUS_MASTER;
    if (disableIntx) cmd |= PCI_CMD_INT_DISABLE;
    pciWrite16(d.bus, d.dev, d.func, PCI_OFF_COMMAND, cmd);
}

/**
 * Find a PCI capability for the given device.
 * Returns config-space offset, or 0 if not present.
 */
ubyte pciDeviceFindCap(PciDevice* d, ubyte capId) {
    return pciFindCap(d.bus, d.dev, d.func, capId);
}

// ─── MSI helpers ─────────────────────────────────────────────────────────────

/// MSI capability structure (32-bit address variant).
struct MsiCap32 {
    ushort  msgCtrl;    // +2 from cap base
    uint    msgAddr;    // +4
    ushort  msgData;    // +8
}

/// MSI capability structure (64-bit address variant).
struct MsiCap64 {
    ushort  msgCtrl;    // +2
    uint    msgAddrLo;  // +4
    uint    msgAddrHi;  // +8
    ushort  msgData;    // +12
}

/**
 * Program MSI on a device.
 *
 * Params:
 *   d       = target device
 *   lapicId = destination LAPIC ID (physical mode)
 *   vector  = IDT vector number to deliver
 *
 * Returns: true on success, false if no MSI capability.
 *
 * The message address targets LAPIC register 0xFEE0_0000 with:
 *   bits [19:12] = destination LAPIC ID
 * The message data encodes:
 *   bits [7:0]   = vector
 *   bits [10:8]  = delivery mode (000 = Fixed)
 *   bit  [14]    = level (0 = edge)
 */
bool pciEnableMsi(PciDevice* d, ubyte lapicId, ubyte vector) {
    ubyte cap = pciFindCap(d.bus, d.dev, d.func, PCI_CAP_MSI);
    if (!cap) return false;

    ushort ctrl = pciRead16(d.bus, d.dev, d.func, cast(ubyte)(cap + 2));
    bool is64   = (ctrl & 0x0080) != 0;

    // Message address: LAPIC base | (lapicId << 12)
    uint  addrLo = 0xFEE0_0000 | (cast(uint)lapicId << 12);
    ushort data  = cast(ushort)(vector & 0xFF); // Fixed, edge

    if (is64) {
        pciWrite32(d.bus, d.dev, d.func, cast(ubyte)(cap + 4), addrLo);
        pciWrite32(d.bus, d.dev, d.func, cast(ubyte)(cap + 8), 0);       // addrHi
        pciWrite16(d.bus, d.dev, d.func, cast(ubyte)(cap + 12), data);
    } else {
        pciWrite32(d.bus, d.dev, d.func, cast(ubyte)(cap + 4), addrLo);
        pciWrite16(d.bus, d.dev, d.func, cast(ubyte)(cap + 8), data);
    }

    // Enable MSI (bit 0 of msgCtrl), single vector
    ctrl = cast(ushort)((ctrl & ~0x0070) | 0x0001);
    pciWrite16(d.bus, d.dev, d.func, cast(ubyte)(cap + 2), ctrl);

    // Disable legacy INTx while MSI is active
    pciEnableDevice(d, true, false, true, true);
    return true;
}

// ─── debug dump (optional, link only in debug builds) ────────────────────────

//version (PciDebug) {

    void pciDumpDevices() {
        auto flags = save_interrupts();
        klog!"[pci] %u devices found\n"(g_deviceCount);
        for (uint i = 0; i < g_deviceCount; i++) {
            PciDevice* d = &g_devices[i];
            klog!"[pci] %02x:%02x.%x  %04x:%04x  class %02x:%02x  irq %u\n"(
                d.bus, d.dev, d.func,
                d.vendorId, d.deviceId,
                d.classCode, d.subclass,
                d.intLine);
            for (ubyte b = 0; b < 6; b++) {
                if (!d.bars[b].valid) continue;
                klog!"         BAR%u  %s  base=%016lx  size=%lx\n"(
                    b,
                    d.bars[b].isIo ? "IO  " : "MEM ",
                    d.bars[b].address,
                    d.bars[b].size);
            }
        }
        restore_interrupts(flags);
    }
//}
