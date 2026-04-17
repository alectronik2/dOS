module object;

import lib.print;
import mm.heap;

const MAX_CPUS         = 24;
const PAGE_SIZE        = 4096;
const PAGE_SHIFT       = 12;

const KERNEL_VMA       = 0xFFFFFFFF80000000;
const KERNEL_PMA       = 0x100000;

const PAGES_PER_TCB    = 2;
const TCBSIZE          = PAGES_PER_TCB * PAGE_SIZE;
const TCBMASK          = ~(TCBSIZE - 1UL);

alias usize  = ulong;
alias status = ulong;

alias u8 = ubyte;
alias u16 = ushort;
alias u32 = uint;
alias u64 = ulong;

alias i8 = byte;
alias i16 = short;
alias i32 = int;
alias i64 = long;

alias paddr = u64;
alias vaddr = u64;

alias Handle = u64;

enum Status {
    Ok = 0,
    Inval,
    Exist,
    NoMem,
    NotFound,
    TimeOut,
}

alias size_t    = typeof(int.sizeof);
alias ptrdiff_t = typeof(cast(void*) 0 - cast(void*) 0);
alias noreturn  = typeof(*null);

alias string  = immutable(char)[];
alias wstring = immutable(wchar)[];
alias dstring = immutable(dchar)[];

alias sizediff_t = ptrdiff_t;
alias hash_t     = size_t;
alias equals_t   = bool;

const INFINITE   = 0xFFFF_FFFF_FFFF_FFFF;

/* ================================================================== */
/* Internal helpers (needed before any class can use string ==)        */
/* ================================================================== */

/** Element-wise array equality — the compiler rewrites `==` on slices
  * to a call to this template. */
bool __equals(T1, T2)(scope const T1[] lhs, scope const T2[] rhs)
{
    if (lhs.length != rhs.length)
        return false;
    foreach (i; 0 .. lhs.length)
        if (lhs[i] != rhs[i])
            return false;
    return true;
}

/** Needed for hashing support. */
size_t hashOf(T)(scope const T val) @trusted
{
    static if (is(T == string) || is(T : const(char)[]))
    {
        size_t h = 5381;
        auto s = cast(const(ubyte)[]) val;
        foreach (i; 0 .. s.length)
            h = h * 33 + s[i];
        return h;
    }
    else
    {
        return cast(size_t) cast(const(void)*) &val;
    }
}

/* ================================================================== */
/* GC info constants                                                   */
/* ================================================================== */

enum immutable(void)* rtinfoNoPointers  = null;
enum immutable(void)* rtinfoHasPointers = cast(void*) 1;

/* ================================================================== */
/* Support structs                                                     */
/* ================================================================== */

struct Interface
{
    TypeInfo_Class classinfo;
    void*[]        vtbl;
    size_t         offset;
}

struct OffsetTypeInfo
{
    size_t   offset;
    TypeInfo ti;
}

/* ================================================================== */
/* Object — root of the D class hierarchy                              */
/* ================================================================== */

class Object
{
    string toString()
    {
        return "Object";
    }

    size_t toHash() @trusted nothrow
    {
        size_t addr = cast(size_t) cast(void*) this;
        return addr ^ (addr >>> 4);
    }

    int opCmp(Object o)
    {
        auto a = cast(size_t) cast(void*) this;
        auto b = cast(size_t) cast(void*) o;
        return (a > b) - (a < b);
    }

    bool opEquals(Object o)
    {
        return this is o;
    }

    static Object factory(string classname)
    {
        return null;
    }
}

/* ================================================================== */
/* TypeInfo — runtime type information base class                      */
/*                                                                      */
/* NOT abstract under LDC: used as TypeInfo for typeof(null).          */
/* Virtual method order must match system druntime exactly.            */
/* ================================================================== */

class TypeInfo
{
    override string toString() const { return "TypeInfo"; }

    override size_t toHash() @trusted const { return 0; }

    override int opCmp(Object rhs)
    {
        if (this is rhs) return 0;
        return 1;
    }

    override bool opEquals(Object o)
    {
        return opEquals(cast(TypeInfo) cast(void*) o);
    }

    bool opEquals(const TypeInfo ti) const
    {
        return this is ti;
    }

    size_t getHash(scope const void* p) @trusted nothrow const
    {
        return 0;
    }

    bool equals(in void* p1, in void* p2) const
    {
        return p1 == p2;
    }

    int compare(in void* p1, in void* p2) const
    {
        return 0;
    }

    @property size_t tsize() pure const @safe
    {
        return 0;
    }

    @property inout(TypeInfo) next() pure inout
    {
        return null;
    }

    const(void)[] initializer() pure const @trusted
    {
        return (cast(const(void)*) null)[0 .. typeof(null).sizeof];
    }

    @property uint flags() pure const @safe
    {
        return 0;
    }

    const(OffsetTypeInfo)[] offTi() const
    {
        return null;
    }

    void destroy(void* p) const {}
    void postblit(void* p) const {}

    @property size_t talign() pure const @safe
    {
        return tsize;
    }

    /* WithArgTypes: active on x86_64 non-Windows */
    int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe
    {
        arg1 = this;
        return 0;
    }

    @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoHasPointers;
    }
}

/* ================================================================== */
/* TypeInfo_Class                                                       */
/*                                                                      */
/* Data field order is critical — compiler accesses by offset.         */
/* Matches /usr/include/dlang/ldc/object.d lines 1700–1731.           */
/* ================================================================== */

class TypeInfo_Class : TypeInfo
{
    override string toString() const pure { return name; }

    override bool opEquals(Object o)
    {
        auto c = cast(TypeInfo_Class) cast(void*) o;
        return c && this.name == c.name;
    }

    override size_t getHash(scope const void* p) @trusted nothrow const
    {
        auto o = *cast(Object*) p;
        return o ? o.toHash() : 0;
    }

    override bool equals(in void* p1, in void* p2) const
    {
        Object o1 = *cast(Object*) p1;
        Object o2 = *cast(Object*) p2;
        return (o1 is o2) || (o1 && o1.opEquals(o2));
    }

    override int compare(in void* p1, in void* p2) const
    {
        Object o1 = *cast(Object*) p1;
        Object o2 = *cast(Object*) p2;
        if (o1 is o2) return 0;
        if (!o1) return -1;
        if (!o2) return 1;
        return o1.opCmp(o2);
    }

    override @property size_t tsize() pure const
    {
        return Object.sizeof;
    }

    override const(void)[] initializer() pure const @safe
    {
        return m_init;
    }

    override @property uint flags() pure const { return 1; }

    override @property const(OffsetTypeInfo)[] offTi() pure const
    {
        return m_offTi;
    }

    override @property immutable(void)* rtInfo() const { return m_RTInfo; }

    /* --- Data fields (order-critical, must match system druntime) --- */

    byte[]      m_init;
    string      name;
    void*[]     vtbl;
    Interface[] interfaces;
    TypeInfo_Class base;
    void*       destructor;
    void function(Object) classInvariant;

    enum ClassFlags : ushort
    {
        isCOMclass    = 0x1,
        noPointers    = 0x2,
        hasOffTi      = 0x4,
        hasCtor       = 0x8,
        hasGetMembers = 0x10,
        hasTypeInfo   = 0x20,
        isAbstract    = 0x40,
        isCPPclass    = 0x80,
        hasDtor       = 0x100,
        hasNameSig    = 0x200,
    }

    ClassFlags          m_flags;
    ushort              depth;
    void*               deallocator;
    OffsetTypeInfo[]    m_offTi;
    void function(Object) defaultConstructor;
    immutable(void)*    m_RTInfo;
    uint[4]             nameSig;

    final @property auto info() @safe pure const return { return this; }
    final @property auto typeinfo() @safe pure const return { return this; }

    final bool isBaseOf(scope const TypeInfo_Class child) const pure @trusted
    {
        for (auto ti = cast(TypeInfo_Class) cast(void*) child; ti !is null; ti = ti.base)
            if (ti is this) return true;
        return false;
    }
}

alias ClassInfo = TypeInfo_Class;

/* ================================================================== */
/* TypeInfo_Enum                                                       */
/* ================================================================== */

class TypeInfo_Enum : TypeInfo
{
    override string toString() const pure { return name; }

    override const(void)[] initializer() const
    {
        return m_init.length ? m_init : base.initializer();
    }

    override @property size_t tsize() pure const { return base.tsize; }
    override @property inout(TypeInfo) next() pure inout { return base.next; }
    override @property uint flags() pure const { return base.flags; }
    override @property size_t talign() pure const { return base.talign; }

    override int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe
    {
        return base.argTypes(arg1, arg2);
    }

    override @property immutable(void)* rtInfo() const { return base.rtInfo; }

    TypeInfo base;
    string   name;
    void[]   m_init;
}

/* ================================================================== */
/* TypeInfo_Pointer                                                    */
/* ================================================================== */

class TypeInfo_Pointer : TypeInfo
{
    override @property size_t tsize() pure const { return (void*).sizeof; }

    override const(void)[] initializer() const @trusted
    {
        return (cast(void*) null)[0 .. (void*).sizeof];
    }

    override @property inout(TypeInfo) next() pure inout { return m_next; }
    override @property uint flags() pure const { return 1; }

    TypeInfo m_next;
}

/* ================================================================== */
/* TypeInfo_Array                                                      */
/* ================================================================== */

class TypeInfo_Array : TypeInfo
{
    override @property size_t tsize() pure const { return (void[]).sizeof; }

    override const(void)[] initializer() const @trusted
    {
        return (cast(void*) null)[0 .. (void[]).sizeof];
    }

    override @property inout(TypeInfo) next() pure inout { return value; }
    override @property uint flags() pure const { return 1; }
    override @property size_t talign() pure const { return (void[]).alignof; }

    override int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe
    {
        return 0;
    }

    override @property immutable(void)* rtInfo() pure const @safe { return null; }

    TypeInfo value;
}

/* ================================================================== */
/* TypeInfo_StaticArray                                                 */
/* ================================================================== */

class TypeInfo_StaticArray : TypeInfo
{
    override @property size_t tsize() pure const { return value.tsize * len; }
    override const(void)[] initializer() const { return value.initializer(); }
    override @property inout(TypeInfo) next() pure inout { return value; }

    TypeInfo value;
    size_t   len;
}

/* ================================================================== */
/* TypeInfo_AssociativeArray                                            */
/* ================================================================== */

class TypeInfo_AssociativeArray : TypeInfo
{
    TypeInfo value;
    TypeInfo key;
}

/* ================================================================== */
/* TypeInfo_Vector                                                     */
/* ================================================================== */

class TypeInfo_Vector : TypeInfo
{
    override const(void)[] initializer() pure const { return base.initializer(); }
    override @property size_t tsize() pure const { return base.tsize; }

    TypeInfo base;
}

/* ================================================================== */
/* TypeInfo_Function                                                   */
/* ================================================================== */

class TypeInfo_Function : TypeInfo
{
    override @property size_t tsize() pure const
    {
        return (void function()).sizeof;
    }

    TypeInfo next;
    string   deco;
}

/* ================================================================== */
/* TypeInfo_Delegate                                                   */
/* ================================================================== */

class TypeInfo_Delegate : TypeInfo
{
    override @property size_t tsize() pure const
    {
        return (int delegate()).sizeof;
    }

    TypeInfo next;
    string   deco;
}

/* ================================================================== */
/* TypeInfo_Interface                                                  */
/* ================================================================== */

class TypeInfo_Interface : TypeInfo
{
    override string toString() const pure
    {
        return info ? info.name : null;
    }

    override @property size_t tsize() pure const { return Object.sizeof; }

    override const(void)[] initializer() const @trusted
    {
        return (cast(void*) null)[0 .. Object.sizeof];
    }

    TypeInfo_Class info;
}

/* ================================================================== */
/* TypeInfo_Struct                                                     */
/*                                                                      */
/* Field order must match system druntime exactly.                     */
/* WithArgTypes: m_arg1, m_arg2 come BEFORE m_RTInfo.                 */
/* ================================================================== */

class TypeInfo_Struct : TypeInfo
{
    override string toString() const { return mangledName; }

    override @property size_t tsize() pure const
    {
        return initializer().length;
    }

    override const(void)[] initializer() pure const @safe
    {
        return m_init;
    }

    override @property uint flags() pure const { return m_flags; }
    override @property size_t talign() pure const { return m_align; }
    override @property immutable(void)* rtInfo() pure const @safe { return m_RTInfo; }

    override int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe
    {
        arg1 = m_arg1;
        arg2 = m_arg2;
        return 0;
    }

    /* --- Data fields (order must match system druntime) --- */

    string mangledName;
    void[] m_init;

    @safe pure nothrow
    {
        size_t function(in void*) xtoHash;
        bool   function(in void*, in void*) xopEquals;
        int    function(in void*, in void*) xopCmp;
        string function(in void*) xtoString;

        enum StructFlags : uint
        {
            hasPointers   = 0x1,
            isDynamicType = 0x2,
        }

        StructFlags m_flags;
    }

    union
    {
        void function(void*) xdtor;
        void function(void*, const TypeInfo_Struct ti) xdtorti;
    }

    void function(void*) xpostblit;
    uint m_align;

    /* WithArgTypes: these come BEFORE m_RTInfo */
    TypeInfo m_arg1;
    TypeInfo m_arg2;

    immutable(void)* m_RTInfo;
}

/* ================================================================== */
/* TypeInfo_Tuple                                                      */
/* ================================================================== */

class TypeInfo_Tuple : TypeInfo
{
    TypeInfo[] elements;
}

/* ================================================================== */
/* Qualifier wrapper TypeInfos                                         */
/* ================================================================== */

class TypeInfo_Const : TypeInfo
{
    override @property size_t tsize() pure const { return base.tsize; }
    override const(void)[] initializer() pure const { return base.initializer(); }
    override @property inout(TypeInfo) next() pure inout { return base.next; }

    TypeInfo base;
}

class TypeInfo_Invariant : TypeInfo_Const {}
class TypeInfo_Shared    : TypeInfo_Const {}
class TypeInfo_Inout     : TypeInfo_Const {}

/* ================================================================== */
/* Basic type TypeInfos                                                */
/*                                                                      */
/* The compiler generates references to these for fundamental types.   */
/* The naming convention uses D's type mangling:                       */
/*   v=void h=ubyte g=byte t=ushort s=short k=uint i=int              */
/*   m=ulong l=long b=bool a=char w=wchar d=dchar                     */
/* ================================================================== */

class TypeInfo_v : TypeInfo /* void */
{
    override @property size_t tsize() pure const { return 1; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. 1];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_h : TypeInfo /* ubyte */
{
    override @property size_t tsize() pure const { return ubyte.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. ubyte.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_g : TypeInfo /* byte */
{
    override @property size_t tsize() pure const { return byte.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. byte.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_t : TypeInfo /* ushort */
{
    override @property size_t tsize() pure const { return ushort.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. ushort.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_s : TypeInfo /* short */
{
    override @property size_t tsize() pure const { return short.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. short.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_k : TypeInfo /* uint */
{
    override @property size_t tsize() pure const { return uint.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. uint.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_i : TypeInfo /* int */
{
    override @property size_t tsize() pure const { return int.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. int.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_m : TypeInfo /* ulong */
{
    override @property size_t tsize() pure const { return ulong.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. ulong.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_l : TypeInfo /* long */
{
    override @property size_t tsize() pure const { return long.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. long.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_b : TypeInfo /* bool */
{
    override @property size_t tsize() pure const { return bool.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. bool.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_a : TypeInfo /* char */
{
    override @property size_t tsize() pure const { return char.sizeof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. char.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_u : TypeInfo /* wchar */
{
    override @property size_t tsize() pure const { return wchar.sizeof; }
    override @property size_t talign() pure const { return wchar.alignof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. wchar.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_w : TypeInfo /* dchar */
{
    override @property size_t tsize() pure const { return dchar.sizeof; }
    override @property size_t talign() pure const { return dchar.alignof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. dchar.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_f : TypeInfo /* float */
{
    override @property size_t tsize() pure const { return float.sizeof; }
    override @property size_t talign() pure const { return float.alignof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. float.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
    override int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe
    {
        arg1 = this;
        return 0;
    }
}

class TypeInfo_d : TypeInfo /* double */
{
    override @property size_t tsize() pure const { return double.sizeof; }
    override @property size_t talign() pure const { return double.alignof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. double.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
    override int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe
    {
        arg1 = this;
        return 0;
    }
}

class TypeInfo_e : TypeInfo /* real (80-bit extended) */
{
    override @property size_t tsize() pure const { return real.sizeof; }
    override @property size_t talign() pure const { return real.alignof; }
    override const(void)[] initializer() const @trusted
    {
        return (cast(const(void)*) null)[0 .. real.sizeof];
    }
    override @property immutable(void)* rtInfo() pure const @trusted
    {
        return rtinfoNoPointers;
    }
}

class TypeInfo_Aa : TypeInfo_Array /* string = immutable(char)[] */
{
}

class TypeInfo_Aya : TypeInfo_Array /* immutable(char)[] */
{
}

/* ================================================================== */
/* Throwable hierarchy                                                 */
/*                                                                      */
/* Field layout must match system druntime — compiler may access by   */
/* offset. We provide minimal stubs (no actual throw/catch support).   */
/* ================================================================== */

class Throwable : Object
{
    interface TraceInfo
    {
        int opApply(scope int delegate(ref const(char[]))) const;
        int opApply(scope int delegate(ref size_t, ref const(char[]))) const;
        string toString() const;
    }

    alias TraceDeallocator = void function(TraceInfo) nothrow;

    string          msg;
    string          file;
    size_t          line;
    TraceInfo       info;
    TraceDeallocator infoDeallocator;
    private Throwable nextInChain;
    private uint      _refcount;

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain = null)
    {
        this.msg = msg;
        this.nextInChain = nextInChain;
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable nextInChain = null)
    {
        this(msg, nextInChain);
        this.file = file;
        this.line = line;
    }

    override string toString() { return msg; }

    @property inout(Throwable) next() @safe inout return scope pure nothrow @nogc
    {
        return nextInChain;
    }

    @property void next(Throwable tail) @safe scope pure nothrow @nogc
    {
        nextInChain = tail;
    }

    @system @nogc final pure nothrow ref uint refcount() return { return _refcount; }

    const(char)[] message() const @safe nothrow { return this.msg; }
}

class Exception : Throwable
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__,
                                  size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain,
                                  string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, nextInChain);
    }
}

class Error : Throwable
{
    Throwable bypassedException;

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain = null)
    {
        super(msg, nextInChain);
        bypassedException = null;
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
        bypassedException = null;
    }
}

/* ================================================================== */
/* Runtime stubs                                                       */
/*                                                                      */
/* extern(C) functions that ldc2 may emit calls to when classes,       */
/* asserts, or bounds checks are used.                                 */
/* ================================================================== */

private extern(C) void* memcpy(void*, const(void)*, size_t);
private extern(C) void* memset(void*, int, size_t);

/* ---- @nogc class allocator ---- */

/**
 * Allocate and construct a D class instance using kmalloc.
 *
 * Usage:  auto obj = knew!MyClass(args...);
 *
 * This is the @nogc equivalent of `new MyClass(args)`.
 * Uses __traits(initSymbol) to copy the static initialiser
 * (which sets up the vtable pointer), then calls the constructor.
 */
T knew(T, Args...)(Args args) @trusted if (is(T == class))
{
    auto init = __traits(initSymbol, T);
    auto p = kmalloc!T(init.length);
    if (p is null) return null;
    memcpy(p, init.ptr, init.length);
    auto obj = cast(T) p;
    static if (__traits(hasMember, T, "__ctor"))
        obj.__ctor(args);
    return obj;
}

/** Free a class instance allocated with knew. */
void kdestroy(T)(T obj) @trusted if (is(T == class)) {
    if (obj is null)
        return;

    auto ci = typeid(obj);
    if (ci.destructor !is null)
        (cast(void function(Object)) ci.destructor)(cast(Object) obj);

    kfree(cast(void*) obj);
}

/* ---- Dynamic cast ---- */

extern(C) Object _d_dynamic_cast(Object o, TypeInfo_Class targetClass)
{
    if (o is null) return null;

    auto oc = typeid(o);

    /* Walk the inheritance chain, checking both base classes and interfaces. */
    for (auto ci = oc; ci !is null; ci = ci.base)
    {
        if (ci is targetClass)
            return o;

        foreach (ref iface; ci.interfaces)
        {
            if (iface.classinfo is targetClass)
            {
                /* Return pointer adjusted to the interface sub-object. */
                return cast(Object) cast(void*)(cast(size_t) cast(void*) o + iface.offset);
            }
        }
    }

    return null;
}

/**
 * Cast an interface pointer back to a class.
 *
 * When p is a pointer to an interface sub-object inside a class instance,
 * the slot immediately before the interface's vtbl (i.e. vtbl[-1]) holds
 * a pointer to the Interface descriptor, whose offset field records how
 * far into the instance the interface lives.  We use that to recover the
 * original Object pointer, then delegate to _d_dynamic_cast.
 */
extern(C) void* _d_interface_cast(void* p, TypeInfo_Class targetClass)
{
    if (p is null) return null;

    /* vtbl[-1] of the interface sub-object is the Interface* descriptor. */
    Interface* pi = **cast(Interface***) p;
    Object o = cast(Object) cast(void*)(cast(size_t) p - pi.offset);
    return cast(void*) _d_dynamic_cast(o, targetClass);
}

/* ---- Template-based cast (required by LDC 1.38+) ---- */

Tret _d_cast(Tret, Tsrc)(Tsrc o) @trusted
{
    return cast(Tret) _d_dynamic_cast(cast(Object) o,
        cast(TypeInfo_Class) typeid(Tret));
}

/* ---- Class allocation ---- */

extern(C) Object _d_allocclass(const TypeInfo_Class ci)
{
    auto init = ci.initializer();
    if (init.length == 0) return null;
    void* p = kmalloc!(void *)(init.length);
    if (p is null)
        kpanic("_d_allocclass: out of memory");
    return cast(Object) p;
}

extern(C) Object _d_newclass(const TypeInfo_Class ci)
{
    auto init = ci.initializer();
    if (init.length == 0) return null;
    void* p = kmalloc!(void *)(init.length);
    if (p is null)
        kpanic("_d_newclass: out of memory");
    memcpy(p, init.ptr, init.length);
    return cast(Object) p;
}

/* ---- Value-type (struct) heap allocation ---- */

T* 
_d_newitemT(T)() {
    enum size = T.sizeof;
    void* ptr = kmalloc!(void*)(size);
    if( ptr is null ) 
        kpanic("_d_newitemT: out of memory");
    memset(ptr, 0, size);
    return cast(T*) ptr;
}

extern(C) void _d_delclass(Object* p) {
    if (p !is null && *p !is null)
    {
        kfree(cast(void*) *p);
        *p = null;
    }
}

extern(C) void _d_delThrowable(scope Throwable) {}

/* ---- Assert stubs ---- */

extern(C) void _d_assert(const(char)[] file, uint line) {
    kprintf("assertion failed: {s}:{i}", file.ptr, line );
}

extern(C) void _d_assert_msg(const(char)[] msg, const(char)[] file, uint line) {
    kprintf("assertion failed ({s}): {s}:{i}", msg.ptr, file.ptr, line );
}

extern(C) void _d_assertp(immutable(void)* file, uint line) {
    kprintf("assertion failed: {s}:{i}", file, line );
}

/* ---- Array bounds stubs ---- */

extern(C) void _d_arraybounds(const(char)[] file, uint line) {
    kprintf("array bounds error: {s}:{i}", file.ptr, line);
}

extern(C) void _d_arraybounds_index(const(char)[] file, uint line,
                                    size_t index, size_t length) {
    kprintf("array index out of bounds: {s}:{i}", file.ptr, line);
}

extern(C) void _d_arraybounds_slice(const(char)[] file, uint line,
                                    size_t lower, size_t upper, size_t length) {
    kprintf("array slice out of bounds: {s}:{i}", file.ptr, line);
}

/* ---- Switch error (final switch with no matching case) ---- */

extern(C) void __switch_error()(const(char)[] file, uint line) {
    kprintf("final switch error: {s}:{i}", file.ptr, line);
}

/* ---- Array helpers ---- */

/**
 * Element-wise dynamic array equality, called by compiler-generated
 * __xopEquals for structs that contain arrays of non-scalar types.
 */
extern(C) bool _adEq2(void[] a1, void[] a2, TypeInfo ti) {
    if (a1.length != a2.length) return false;
    if (a1.ptr is a2.ptr) return true;
    immutable sz = ti.tsize;
    for (size_t i = 0; i < a1.length; i++)
        if (!ti.equals(a1.ptr + i * sz, a2.ptr + i * sz))
            return false;
    return true;
}

/* ---- Comparison helpers ---- */

bool opEquals(Object lhs, Object rhs) {
    if (lhs is rhs) return true;
    if (lhs is null || rhs is null) return false;
    return lhs.opEquals(rhs);
}

bool _xopEquals(in void*, in void*) {
    return false;
}

bool _xopCmp(in void*, in void*) {
    return false;
}

/* ---- Invariant stub ---- */

extern(C) void _D2rt10invariant_12_d_invariantFC6ObjectZv(Object) {}

/* ---- Module-info linked-list head ---- */
/*
 * Without -betterC each module emits a __moduleinfoCtor that prepends its
 * ModuleInfo to the singly-linked list rooted here.  We define the head so
 * the linker is satisfied; in a bare-metal kernel we never walk the list
 * (no rt_init / rt_moduleCtor), so null is fine.
 */
extern(C) __gshared void* _Dmodule_ref = null;
