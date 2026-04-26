module vfs.vfs;

import lib.str, lib.klog, lib.runtime;
import mm.heap;
import object : kdestroy;

const MAXPATH = 2048;

enum VfsNodeKind : ubyte {
    Regular,
    Directory,
    Device,
}

enum VfsOpenFlags : uint {
    Read      = 1 << 0,
    Write     = 1 << 1,
    Create    = 1 << 2,
    Truncate  = 1 << 3,
    Append    = 1 << 4,
    Directory = 1 << 5,
}

struct VfsDirent {
    VfsNodeKind kind;
    String      name;
}

struct VfsStat {
    VfsNodeKind kind;
    size_t      size;
    uint        links;
}

class VfsNode : Object {
    protected String      _name;
    protected VfsNode     _parent;
    protected VfsMount    _mount;
    protected VfsNodeKind _kind;
    protected uint        _links = 1;

    this(const(char)[] name, VfsNode parent, VfsMount mount, VfsNodeKind kind) {
        _name = new String(name);
        _parent = parent;
        _mount = mount;
        _kind = kind;
    }

    ~this() {
        if (_name !is null) {
            kdestroy(_name);
            _name = null;
        }
    }

    @property String name() { return _name; }
    @property VfsNode parent() { return _parent; }
    @property VfsMount mount() { return _mount; }
    @property VfsNodeKind kind() const { return _kind; }
    @property bool isDirectory() const { return _kind == VfsNodeKind.Directory; }
    @property bool isRegular() const { return _kind == VfsNodeKind.Regular; }
    @property uint links() const { return _links; }

    size_t dataSize() const { return 0; }

    Status stat(out VfsStat result) {
        result.kind = _kind;
        result.size = dataSize();
        result.links = _links;
        return Status.Ok;
    }

    VfsNode lookup(const(char)[] name) { return null; }

    Status createChild(const(char)[] name, VfsNodeKind kind, out VfsNode node) {
        node = null;
        return Status.NotDir;
    }

    Status removeChild(const(char)[] name) {
        return Status.NotDir;
    }

    Status read(offset_t offset, void* data, size_t size, out size_t amount) {
        amount = 0;
        return isDirectory ? Status.IsDir : Status.Inval;
    }

    Status write(offset_t offset, const(void)* data, size_t size, out size_t amount) {
        amount = 0;
        return isDirectory ? Status.IsDir : Status.ReadOnly;
    }

    Status truncate(size_t newSize) {
        return isDirectory ? Status.IsDir : Status.ReadOnly;
    }

    Status readdir(size_t index, out VfsDirent entry) {
        entry.kind = VfsNodeKind.Regular;
        entry.name = null;
        return Status.NotDir;
    }
}

private struct TmpfsChildLink {
    VfsNode         node;
    TmpfsChildLink* next;
}

class TmpfsNode : VfsNode {
    this(const(char)[] name, VfsNode parent, VfsMount mount, VfsNodeKind kind) {
        super(name, parent, mount, kind);
    }
}

class TmpfsFile : TmpfsNode {
    private char*  _data;
    private size_t _size;
    private size_t _capacity;

    this(const(char)[] name, VfsNode parent, VfsMount mount) {
        super(name, parent, mount, VfsNodeKind.Regular);
    }

    ~this() {
        if (_data !is null) {
            kfree(_data);
            _data = null;
        }
    }

    override size_t dataSize() const { return _size; }

    override Status read(offset_t offset, void* data, size_t size, out size_t amount) {
        amount = 0;

        if (offset > _size) {
            return Status.Inval;
        }

        auto available = _size - cast(size_t) offset;
        if (available == 0 || size == 0) {
            return Status.Ok;
        }

        amount = size < available ? size : available;
        memcpy(data, _data + cast(size_t) offset, amount);
        return Status.Ok;
    }

    override Status write(offset_t offset, const(void)* data, size_t size, out size_t amount) {
        amount = 0;

        if (size == 0) {
            return Status.Ok;
        }

        auto start = cast(size_t) offset;
        auto end = start + size;
        auto rc = ensureCapacity(end);
        if (failure(rc)) {
            return rc;
        }

        if (start > _size) {
            zeroRange(_data + _size, start - _size);
        }

        memcpy(_data + start, data, size);
        if (end > _size) {
            _size = end;
        }

        amount = size;
        return Status.Ok;
    }

    override Status truncate(size_t newSize) {
        auto rc = ensureCapacity(newSize);
        if (failure(rc)) {
            return rc;
        }

        if (newSize > _size) {
            zeroRange(_data + _size, newSize - _size);
        }

        _size = newSize;
        return Status.Ok;
    }

private:
    Status ensureCapacity(size_t required) {
        if (required <= _capacity) {
            return Status.Ok;
        }

        size_t newCapacity = _capacity == 0 ? 64 : _capacity;
        while (newCapacity < required) {
            if (newCapacity > size_t.max / 2) {
                newCapacity = required;
                break;
            }
            newCapacity *= 2;
        }

        char* replacement;
        if (_data is null) {
            replacement = kmalloc!char(newCapacity);
        } else {
            replacement = krealloc!char(_data, newCapacity);
        }

        if (replacement is null) {
            return Status.NoMem;
        }

        _data = replacement;
        _capacity = newCapacity;
        return Status.Ok;
    }

    void zeroRange(char* start, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            start[i] = 0;
        }
    }
}

class TmpfsDirectory : TmpfsNode {
    private TmpfsChildLink* _children;
    private size_t          _childCount;

    this(const(char)[] name, VfsNode parent, VfsMount mount) {
        super(name, parent, mount, VfsNodeKind.Directory);
    }

    ~this() {
        auto link = _children;
        while (link !is null) {
            auto next = link.next;
            if (link.node !is null) {
                kdestroy(link.node);
            }
            kfree(link);
            link = next;
        }
        _children = null;
        _childCount = 0;
    }

    override VfsNode lookup(const(char)[] name) {
        for (auto link = _children; link !is null; link = link.next) {
            if (link.node.name == name) {
                return link.node;
            }
        }
        return null;
    }

    override Status createChild(const(char)[] name, VfsNodeKind kind, out VfsNode node) {
        node = null;

        if (name.length == 0) {
            return Status.Inval;
        }

        if (lookup(name) !is null) {
            return Status.Exist;
        }

        final switch (kind) {
            case VfsNodeKind.Directory:
                node = new TmpfsDirectory(name, this, mount);
                break;
            case VfsNodeKind.Regular:
                node = new TmpfsFile(name, this, mount);
                break;
            case VfsNodeKind.Device:
                return Status.Inval;
        }

        if (node is null) {
            return Status.NoMem;
        }

        auto link = kmalloc!TmpfsChildLink();
        if (link is null) {
            kdestroy(node);
            node = null;
            return Status.NoMem;
        }

        link.node = node;
        link.next = _children;
        _children = link;
        _childCount++;
        return Status.Ok;
    }

    override Status removeChild(const(char)[] name) {
        TmpfsChildLink* prev = null;
        auto link = _children;

        while (link !is null) {
            if (link.node.name == name) {
                auto dir = cast(TmpfsDirectory) link.node;
                if (dir !is null && dir._childCount != 0) {
                    return Status.NotEmpty;
                }

                if (prev is null) {
                    _children = link.next;
                } else {
                    prev.next = link.next;
                }

                kdestroy(link.node);
                kfree(link);
                _childCount--;
                return Status.Ok;
            }

            prev = link;
            link = link.next;
        }

        return Status.NotFound;
    }

    override Status readdir(size_t index, out VfsDirent entry) {
        entry.kind = VfsNodeKind.Regular;
        entry.name = null;

        size_t current = 0;
        for (auto link = _children; link !is null; link = link.next) {
            if (current == index) {
                entry.kind = link.node.kind;
                entry.name = link.node.name;
                return Status.Ok;
            }
            current++;
        }

        return Status.NotFound;
    }
}

interface IVfsDriver {
    @property String typeName();
    Status mount(devno_t devno, String mountPath, String opts, out VfsNode root);
}

class RegisteredFileSystem : Object {
    RegisteredFileSystem next;
    IVfsDriver           driver;
    String               name;

    this(IVfsDriver driver) {
        this.driver = driver;
        name = driver.typeName().dup();
    }

    ~this() {
        if (name !is null) {
            kdestroy(name);
            name = null;
        }
    }
}

class VfsMount : Object {
    VfsMount  next;
    IVfsDriver driver;
    devno_t   devno;
    String    path;
    VfsNode   root;

    this(IVfsDriver driver, devno_t devno, String path, VfsNode root) {
        this.driver = driver;
        this.devno = devno;
        this.path = path.dup();
        this.root = root;
    }

    ~this() {
        if (path !is null) {
            kdestroy(path);
            path = null;
        }
    }
}

class VfsFile : Object {
    private VfsNode _node;
    private offset_t _offset;
    private uint _flags;

    this(VfsNode node, uint flags) {
        _node = node;
        _flags = flags;
    }

    @property VfsNode node() { return _node; }
    @property offset_t tell() const { return _offset; }
    @property uint flags() const { return _flags; }

    Status read(void* data, size_t size, out size_t amount) {
        auto rc = _node.read(_offset, data, size, amount);
        if (!failure(rc)) {
            _offset += amount;
        }
        return rc;
    }

    Status write(const(void)* data, size_t size, out size_t amount) {
        auto writeOffset = (_flags & VfsOpenFlags.Append) ? cast(offset_t) _node.dataSize : _offset;
        auto rc = _node.write(writeOffset, data, size, amount);
        if (!failure(rc)) {
            _offset = writeOffset + amount;
        }
        return rc;
    }

    Status seek(offset_t offset) {
        _offset = offset;
        return Status.Ok;
    }

    Status truncate(size_t size) {
        return _node.truncate(size);
    }
}

class TmpfsDriver : Object, IVfsDriver {
    private String _typeName;

    this() {
        _typeName = new String("tmpfs");
    }

    ~this() {
        if (_typeName !is null) {
            kdestroy(_typeName);
            _typeName = null;
        }
    }

    @property String typeName() {
        return _typeName;
    }

    Status mount(devno_t devno, String mountPath, String opts, out VfsNode root) {
        root = new TmpfsDirectory("", null, null);
        if (root is null) {
            return Status.NoMem;
        }
        return Status.Ok;
    }
}

class StubFsDriver : Object, IVfsDriver {
    private String _typeName;

    this(const(char)[] name) {
        _typeName = new String(name);
    }

    ~this() {
        if (_typeName !is null) {
            kdestroy(_typeName);
            _typeName = null;
        }
    }

    @property String typeName() {
        return _typeName;
    }

    Status mount(devno_t devno, String mountPath, String opts, out VfsNode root) {
        root = null;
        return Status.Inval;
    }
}

__gshared RegisteredFileSystem gRegisteredFileSystems;
__gshared VfsMount             gMounts;
__gshared bool                 gVfsInitialized;

Status canonicalize(String path_, String buffer) {
    if (path_ is null || buffer is null) return Status.Inval;
    if (path_.length >= MAXPATH) return Status.Inval;

    auto path = path_.view;
    size_t cursor = 0;
    bool rooted = false;

    buffer.clear();

    if (path.length >= 2 && path[0] != 0 && path[1] == ':') {
        cursor = 2;
    }

    if (cursor < path.length && path[cursor] == '/') {
        rooted = true;
    }

    while (cursor < path.length) {
        while (cursor < path.length && path[cursor] == '/') {
            rooted = true;
            cursor++;
        }

        if (cursor >= path.length) {
            break;
        }

        auto start = cursor;
        while (cursor < path.length && path[cursor] != '/') {
            if (path[cursor] < ' ') return Status.Inval;
            cursor++;
        }

        auto part = path[start .. cursor];
        if (part == ".") {
            continue;
        }

        if (part == "..") {
            if (rooted) {
                if (buffer.length <= 1) {
                    buffer.clear();
                    buffer.append('/');
                    continue;
                }

                auto last = buffer.lastIndexOf('/');
                if (last == 0) {
                    buffer.resize(1);
                } else if (last != String.npos) {
                    buffer.resize(last);
                }
                continue;
            }

            if (buffer.length == 0) return Status.Inval;

            auto last = buffer.lastIndexOf('/');
            if (last == String.npos) {
                buffer.clear();
            } else {
                buffer.resize(last);
            }
            continue;
        }

        if (rooted) {
            if (buffer.length == 0) {
                buffer.append('/');
            } else if (buffer[buffer.length - 1] != '/') {
                buffer.append('/');
            }
        } else if (buffer.length != 0) {
            buffer.append('/');
        }

        buffer.append(part);
    }

    if (rooted && buffer.length == 0) {
        buffer.append('/');
    }

    return Status.Ok;
}

Status registerFileSystem(IVfsDriver driver) {
    if (driver is null) return Status.Inval;

    for (auto reg = gRegisteredFileSystems; reg !is null; reg = reg.next) {
        if (reg.name == driver.typeName()) {
            return Status.Exist;
        }
    }

    auto entry = new RegisteredFileSystem(driver);
    if (entry is null) return Status.NoMem;

    entry.next = gRegisteredFileSystems;
    gRegisteredFileSystems = entry;
    return Status.Ok;
}

Status mount(String type, String path, devno_t devno, String opts) {
    if (type is null || path is null) return Status.Inval;

    auto normalized = new String;
    auto rc = canonicalize(path, normalized);
    if (failure(rc)) {
        kdestroy(normalized);
        return rc;
    }

    if (normalized.length == 0 || normalized[0] != '/') {
        kdestroy(normalized);
        return Status.Inval;
    }

    IVfsDriver driver = null;
    for (auto reg = gRegisteredFileSystems; reg !is null; reg = reg.next) {
        if (reg.name == type) {
            driver = reg.driver;
            break;
        }
    }

    if (driver is null) {
        kdestroy(normalized);
        return Status.NotFound;
    }

    for (auto mounted = gMounts; mounted !is null; mounted = mounted.next) {
        if (mounted.path == normalized) {
            kdestroy(normalized);
            return Status.Exist;
        }
    }

    VfsNode root = null;
    rc = driver.mount(devno, normalized, opts, root);
    if (failure(rc) || root is null) {
        if (root !is null) {
            kdestroy(root);
        }
        kdestroy(normalized);
        return failure(rc) ? rc : Status.Inval;
    }

    auto mounted = new VfsMount(driver, devno, normalized, root);
    if (mounted is null) {
        kdestroy(root);
        kdestroy(normalized);
        return Status.NoMem;
    }

    root._mount = mounted;
    mounted.next = gMounts;
    gMounts = mounted;
    kdestroy(normalized);
    return Status.Ok;
}

Status lookup(String path, out VfsNode node) {
    node = null;
    if (path is null) return Status.Inval;

    auto normalized = new String;
    auto rc = canonicalize(path, normalized);
    if (failure(rc)) {
        kdestroy(normalized);
        return rc;
    }

    if (normalized.length == 0 || normalized[0] != '/') {
        kdestroy(normalized);
        return Status.Inval;
    }

    auto mount = findMount(normalized);
    if (mount is null) {
        kdestroy(normalized);
        return Status.NotFound;
    }

    node = mount.root;
    size_t cursor = relativeCursor(mount, normalized);
    auto pathView = normalized.view;

    while (cursor < normalized.length) {
        while (cursor < normalized.length && pathView[cursor] == '/') {
            cursor++;
        }

        if (cursor >= normalized.length) {
            break;
        }

        auto start = cursor;
        while (cursor < normalized.length && pathView[cursor] != '/') {
            cursor++;
        }

        auto part = pathView[start .. cursor];
        if (!node.isDirectory) {
            kdestroy(normalized);
            node = null;
            return Status.NotDir;
        }

        node = node.lookup(part);
        if (node is null) {
            kdestroy(normalized);
            return Status.NotFound;
        }
    }

    kdestroy(normalized);
    return Status.Ok;
}

Status mkdir(String path) {
    VfsNode parent;
    String leaf;
    auto rc = resolveParent(path, parent, leaf);
    if (failure(rc)) {
        return rc;
    }

    scope(exit) if (leaf !is null) kdestroy(leaf);

    VfsNode created = null;
    return parent.createChild(leaf.view, VfsNodeKind.Directory, created);
}

Status unlink(String path) {
    VfsNode parent;
    String leaf;
    auto rc = resolveParent(path, parent, leaf);
    if (failure(rc)) {
        return rc;
    }

    scope(exit) if (leaf !is null) kdestroy(leaf);
    return parent.removeChild(leaf.view);
}

Status open(String path, uint flags, out VfsFile file) {
    file = null;

    VfsNode node = null;
    auto rc = lookup(path, node);
    if (rc == Status.NotFound && (flags & VfsOpenFlags.Create)) {
        VfsNode parent;
        String leaf;
        rc = resolveParent(path, parent, leaf);
        if (failure(rc)) {
            return rc;
        }
        scope(exit) if (leaf !is null) kdestroy(leaf);

        rc = parent.createChild(leaf.view, VfsNodeKind.Regular, node);
        if (failure(rc)) {
            return rc;
        }
    } else if (failure(rc)) {
        return rc;
    }

    if ((flags & VfsOpenFlags.Directory) && !node.isDirectory) {
        return Status.NotDir;
    }
    if (!(flags & VfsOpenFlags.Directory) && node.isDirectory) {
        return Status.IsDir;
    }

    file = new VfsFile(node, flags);
    if (file is null) {
        return Status.NoMem;
    }

    if (flags & VfsOpenFlags.Truncate) {
        rc = file.truncate(0);
        if (failure(rc)) {
            kdestroy(file);
            file = null;
            return rc;
        }
    }

    return Status.Ok;
}

Status writeString(String path, const(char)[] text) {
    VfsFile file;
    auto rc = open(path, VfsOpenFlags.Write | VfsOpenFlags.Create | VfsOpenFlags.Truncate, file);
    if (failure(rc)) {
        return rc;
    }

    size_t written = 0;
    rc = file.write(text.ptr, text.length, written);
    kdestroy(file);
    return rc;
}

Status readString(String path, String output) {
    if (output is null) return Status.Inval;

    VfsNode node;
    auto rc = lookup(path, node);
    if (failure(rc)) {
        return rc;
    }

    auto file = cast(TmpfsFile) node;
    if (file is null) {
        return node.isDirectory ? Status.IsDir : Status.Inval;
    }

    output.clear();
    output.reserve(file.dataSize());

    if (file.dataSize() == 0) {
        return Status.Ok;
    }

    auto buffer = kmalloc!char(file.dataSize());
    if (buffer is null) {
        return Status.NoMem;
    }

    size_t amount = 0;
    rc = file.read(0, buffer, file.dataSize(), amount);
    if (!failure(rc) && amount != 0) {
        output.append(buffer[0 .. amount]);
    }

    kfree(buffer);
    return rc;
}

private VfsMount findMount(String path) {
    VfsMount best = null;
    size_t bestLength = 0;

    for (auto mount = gMounts; mount !is null; mount = mount.next) {
        if (!pathHasPrefix(path, mount.path)) {
            continue;
        }

        if (mount.path.length >= bestLength) {
            best = mount;
            bestLength = mount.path.length;
        }
    }

    return best;
}

private bool pathHasPrefix(String path, String prefix) {
    if (prefix.length == 1 && prefix[0] == '/') {
        return path.length != 0 && path[0] == '/';
    }

    if (prefix.length > path.length) {
        return false;
    }

    auto pathView = path.view;
    auto prefixView = prefix.view;
    for (size_t i = 0; i < prefix.length; ++i) {
        if (pathView[i] != prefixView[i]) {
            return false;
        }
    }

    return path.length == prefix.length || pathView[prefix.length] == '/';
}

private size_t relativeCursor(VfsMount mount, String path) {
    if (mount.path.length == 1 && mount.path[0] == '/') {
        return 1;
    }

    if (path.length == mount.path.length) {
        return path.length;
    }

    return mount.path.length + 1;
}

private Status resolveParent(String path, out VfsNode parent, out String leaf) {
    parent = null;
    leaf = null;

    auto normalized = new String;
    auto rc = canonicalize(path, normalized);
    if (failure(rc)) {
        kdestroy(normalized);
        return rc;
    }

    if (normalized.length == 0 || normalized[0] != '/') {
        kdestroy(normalized);
        return Status.Inval;
    }

    auto last = normalized.lastIndexOf('/');
    if (last == String.npos) {
        kdestroy(normalized);
        return Status.Inval;
    }

    auto normalizedView = normalized.view;
    auto leafView = normalizedView[last + 1 .. $];
    if (leafView.length == 0) {
        kdestroy(normalized);
        return Status.Inval;
    }

    leaf = new String(leafView);
    if (last == 0) {
        rc = lookup(new String("/"), parent);
        kdestroy(normalized);
        return rc;
    }

    auto parentPath = new String(normalizedView[0 .. last]);
    rc = lookup(parentPath, parent);
    kdestroy(parentPath);
    kdestroy(normalized);
    return rc;
}

void vfs_init() {
    if (gVfsInitialized) {
        return;
    }

    auto tmpfs = new TmpfsDriver();
    auto devfs = new StubFsDriver("devfs");
    auto fat16 = new StubFsDriver("fat16");

    assert(registerFileSystem(tmpfs) == Status.Ok);
    assert(registerFileSystem(devfs) == Status.Ok);
    assert(registerFileSystem(fat16) == Status.Ok);

    auto fsName = new String("tmpfs");
    auto rootPath = new String("/");
    auto opts = new String("");
    assert(mount(fsName, rootPath, 0, opts) == Status.Ok);
    kdestroy(fsName);
    kdestroy(rootPath);
    kdestroy(opts);

    auto normalized = new String;
    assert(canonicalize(new String("/mnt/../home/test.txt"), normalized) == Status.Ok);
    assert(normalized == "/home/test.txt");
    kdestroy(normalized);

    assert(mkdir(new String("/home")) == Status.Ok);
    assert(mkdir(new String("/home/user")) == Status.Ok);
    assert(writeString(new String("/home/user/readme.txt"), "hello tmpfs") == Status.Ok);

    auto readBack = new String;
    assert(readString(new String("/home/user/readme.txt"), readBack) == Status.Ok);
    assert(readBack == "hello tmpfs");

    VfsNode node;
    assert(lookup(new String("/home/user/readme.txt"), node) == Status.Ok);
    assert(node.kind == VfsNodeKind.Regular);

    auto appended = new String(" again");
    VfsFile file;
    assert(open(new String("/home/user/readme.txt"), VfsOpenFlags.Write | VfsOpenFlags.Append, file) == Status.Ok);
    size_t written;
    assert(file.write(appended.ptr, appended.length, written) == Status.Ok);
    kdestroy(file);
    kdestroy(appended);

    readBack.clear();
    assert(readString(new String("/home/user/readme.txt"), readBack) == Status.Ok);
    assert(readBack == "hello tmpfs again");

    kdestroy(readBack);
    gVfsInitialized = true;
    klog!"VFS initialized with tmpfs root.";
}
