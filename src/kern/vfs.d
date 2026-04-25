module kern.vfs;

import lib.klog, lib.lock;
import kern.object : KObject;
import mm.heap;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

enum InodeType : u8 {
    File = 0,
    Dir  = 1,
}

enum OpenFlags : u32 {
    Read      = 0x01,
    Write     = 0x02,
    ReadWrite = 0x03,
    Create    = 0x04,
    Trunc     = 0x08,
    Append    = 0x10,
}

enum SeekWhence : u32 {
    Set = 0,
    Cur = 1,
    End = 2,
}

struct VfsStat {
    u64       ino;
    u64       size;
    InodeType type;
    u32       nlink;
}

enum MAX_NAME = 256;

struct DirEntry {
    u64       ino;
    InodeType type;
    u32       name_len;
    char[MAX_NAME] name;
}

// ─────────────────────────────────────────────────────────────────────────────
// Inode operations function pointer table
// ─────────────────────────────────────────────────────────────────────────────

alias ReadFn     = Status function(Inode* inode, u64 offset, ubyte* buf, u64 len, u64* bytes_read);
alias WriteFn    = Status function(Inode* inode, u64 offset, const(ubyte)* buf, u64 len, u64* bytes_written);
alias TruncFn    = Status function(Inode* inode, u64 size);
alias LookupFn   = Inode* function(Inode* dir, const(char)[] name);
alias CreateFn   = Status function(Inode* dir, const(char)[] name, InodeType type, Inode** result);
alias UnlinkFn   = Status function(Inode* dir, const(char)[] name);
alias ReaddirFn  = Status function(Inode* dir, u64 offset, DirEntry* entry, u64* next_offset);
alias StatFn     = Status function(Inode* inode, VfsStat* st);
alias RenameFn   = Status function(Inode* old_dir, const(char)[] old_name, Inode* new_dir, const(char)[] new_name);

struct InodeOps {
    ReadFn     read;
    WriteFn    write;
    TruncFn    truncate;
    LookupFn   lookup;
    CreateFn   create;
    UnlinkFn   unlink;
    ReaddirFn  readdir;
    StatFn     stat;
    RenameFn   rename;
}

// ─────────────────────────────────────────────────────────────────────────────
// Inode
// ─────────────────────────────────────────────────────────────────────────────

struct Inode {
    u64        ino;
    InodeType  type;
    u32        nlink;
    u64        size;
    u32        refcount;
    SpinLock   lock;
    InodeOps*  ops;
    SuperBlock* sb;
    void*      fs_data;
}

void inode_ref(Inode* i) {
    if (i) i.refcount++;
}

void inode_unref(Inode* i) {
    if (i is null) return;
    if (i.refcount > 0) i.refcount--;
}

// ─────────────────────────────────────────────────────────────────────────────
// SuperBlock
// ─────────────────────────────────────────────────────────────────────────────

struct SuperBlock {
    Inode*    root;
    u64       next_ino;
    void*     fs_data;

    u64 alloc_ino() {
        return next_ino++;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mount table
// ─────────────────────────────────────────────────────────────────────────────

struct MountEntry {
    Inode*      mount_point;  // the directory inode that is overlaid
    SuperBlock* sb;           // the mounted filesystem
}

enum MAX_MOUNTS = 16;

__gshared {
    Inode*     vfs_root;
    MountEntry[MAX_MOUNTS] mount_table;
    u32        mount_count;
}

// Check if an inode is a mount point; if so return the root of the mounted fs.
private Inode* check_mount(Inode* inode) {
    for (u32 i = 0; i < mount_count; i++) {
        if (mount_table[i].mount_point is inode)
            return mount_table[i].sb.root;
    }
    return inode;
}

Status vfs_mount(Inode* mountpoint, SuperBlock* sb) {
    if (mountpoint is null || sb is null)
        return Status.Inval;
    if (mountpoint.type != InodeType.Dir)
        return Status.NotDir;
    if (mount_count >= MAX_MOUNTS)
        return Status.NoSpace;

    mount_table[mount_count].mount_point = mountpoint;
    mount_table[mount_count].sb = sb;
    mount_count++;
    return Status.Ok;
}

// ─────────────────────────────────────────────────────────────────────────────
// FileDescription — goes into HandleTable, user gets a Handle
// ─────────────────────────────────────────────────────────────────────────────

class FileDescription : KObject {
    Inode*    inode;
    u64       offset;
    OpenFlags flags;

    this(Inode* i, OpenFlags f) {
        this.inode  = i;
        this.offset = 0;
        this.flags  = f;
        inode_ref(i);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Path resolution
// ─────────────────────────────────────────────────────────────────────────────

// Split a path component from a path. Returns the component and advances the slice.
private const(char)[] next_component(ref const(char)[] path) {
    // skip leading slashes
    while (path.length > 0 && path[0] == '/')
        path = path[1 .. $];

    if (path.length == 0)
        return null;

    size_t i = 0;
    while (i < path.length && path[i] != '/')
        i++;

    auto comp = path[0 .. i];
    path = path[i .. $];
    return comp;
}

// Compare two char slices
private bool streq(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    for (size_t i = 0; i < a.length; i++)
        if (a[i] != b[i]) return false;
    return true;
}

Inode* resolve_path(const(char)[] path, Inode* cwd) {
    Inode* cur;

    if (path.length == 0)
        return cwd ? check_mount(cwd) : vfs_root;

    if (path[0] == '/')
        cur = vfs_root;
    else
        cur = cwd ? cwd : vfs_root;

    cur = check_mount(cur);

    auto remaining = path;
    while (true) {
        auto comp = next_component(remaining);
        if (comp is null)
            break;

        if (cur.type != InodeType.Dir)
            return null;

        if (streq(comp, ".")) {
            continue;
        }

        if (streq(comp, "..")) {
            // For "..", use the lookup op which should handle parent
            if (cur.ops && cur.ops.lookup) {
                auto parent = cur.ops.lookup(cur, "..");
                if (parent !is null)
                    cur = check_mount(parent);
            }
            continue;
        }

        if (cur.ops is null || cur.ops.lookup is null)
            return null;

        auto child = cur.ops.lookup(cur, comp);
        if (child is null)
            return null;

        cur = check_mount(child);
    }

    return cur;
}

struct ResolveResult {
    Inode* parent;
    char[MAX_NAME] basename;
    u32 basename_len;
}

ResolveResult resolve_parent(const(char)[] path, Inode* cwd) {
    ResolveResult result;
    result.parent = null;
    result.basename_len = 0;

    if (path.length == 0)
        return result;

    // Find the last '/' to split parent path from basename
    size_t last_slash = path.length; // sentinel
    for (size_t i = path.length; i > 0; i--) {
        if (path[i - 1] == '/') {
            last_slash = i - 1;
            break;
        }
    }

    const(char)[] parent_path;
    const(char)[] basename;

    if (last_slash == path.length) {
        // No slash found — parent is cwd, basename is entire path
        parent_path = ".";
        basename = path;
    } else if (last_slash == 0) {
        // Leading slash only — parent is root
        parent_path = "/";
        basename = path[1 .. $];
    } else {
        parent_path = path[0 .. last_slash];
        basename = path[last_slash + 1 .. $];
    }

    // Strip trailing slashes from basename
    while (basename.length > 0 && basename[$ - 1] == '/')
        basename = basename[0 .. $ - 1];

    if (basename.length == 0 || basename.length >= MAX_NAME)
        return result;

    result.parent = resolve_path(parent_path, cwd);
    result.basename_len = cast(u32)basename.length;
    result.basename[0 .. basename.length] = basename[];
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// VFS API
// ─────────────────────────────────────────────────────────────────────────────

FileDescription vfs_open(const(char)[] path, OpenFlags flags, Inode* cwd) {
    auto inode = resolve_path(path, cwd);

    if (inode is null) {
        // If Create flag set, try to create
        if (flags & OpenFlags.Create) {
            auto res = resolve_parent(path, cwd);
            if (res.parent is null)
                return null;
            auto name = cast(const(char)[])res.basename[0 .. res.basename_len];
            Inode* new_inode;
            if (res.parent.ops && res.parent.ops.create) {
                auto st = res.parent.ops.create(res.parent, name, InodeType.File, &new_inode);
                if (st != Status.Ok)
                    return null;
                inode = new_inode;
            } else {
                return null;
            }
        } else {
            return null;
        }
    }

    if (inode.type == InodeType.Dir && (flags & OpenFlags.Write))
        return null; // can't open dir for writing

    if ((flags & OpenFlags.Trunc) && inode.type == InodeType.File) {
        if (inode.ops && inode.ops.truncate)
            inode.ops.truncate(inode, 0);
    }

    auto fd = knew!FileDescription(inode, flags);
    return fd;
}

Status vfs_read(FileDescription fd, ubyte* buf, u64 len, u64* bytes_read) {
    if (fd is null || fd.inode is null)
        return Status.Inval;
    if (fd.inode.ops is null || fd.inode.ops.read is null)
        return Status.Inval;

    auto st = fd.inode.ops.read(fd.inode, fd.offset, buf, len, bytes_read);
    if (st == Status.Ok)
        fd.offset += *bytes_read;
    return st;
}

Status vfs_write(FileDescription fd, const(ubyte)* buf, u64 len, u64* bytes_written) {
    if (fd is null || fd.inode is null)
        return Status.Inval;
    if (fd.inode.ops is null || fd.inode.ops.write is null)
        return Status.Inval;

    u64 write_offset = fd.offset;
    if (fd.flags & OpenFlags.Append)
        write_offset = fd.inode.size;

    auto st = fd.inode.ops.write(fd.inode, write_offset, buf, len, bytes_written);
    if (st == Status.Ok) {
        if (fd.flags & OpenFlags.Append)
            fd.offset = fd.inode.size;
        else
            fd.offset += *bytes_written;
    }
    return st;
}

void vfs_close(FileDescription fd) {
    if (fd is null) return;
    inode_unref(fd.inode);
}

Status vfs_stat(const(char)[] path, Inode* cwd, VfsStat* st) {
    auto inode = resolve_path(path, cwd);
    if (inode is null)
        return Status.NotFound;
    if (inode.ops && inode.ops.stat)
        return inode.ops.stat(inode, st);
    // Fill from inode fields directly
    st.ino   = inode.ino;
    st.size  = inode.size;
    st.type  = inode.type;
    st.nlink = inode.nlink;
    return Status.Ok;
}

Status vfs_readdir(FileDescription fd, DirEntry* entry) {
    if (fd is null || fd.inode is null)
        return Status.Inval;
    if (fd.inode.type != InodeType.Dir)
        return Status.NotDir;
    if (fd.inode.ops is null || fd.inode.ops.readdir is null)
        return Status.Inval;

    u64 next_offset;
    auto st = fd.inode.ops.readdir(fd.inode, fd.offset, entry, &next_offset);
    if (st == Status.Ok)
        fd.offset = next_offset;
    return st;
}

Status vfs_mkdir(const(char)[] path, Inode* cwd) {
    auto res = resolve_parent(path, cwd);
    if (res.parent is null)
        return Status.NotFound;
    if (res.parent.type != InodeType.Dir)
        return Status.NotDir;
    if (res.parent.ops is null || res.parent.ops.create is null)
        return Status.Permission;

    auto name = cast(const(char)[])res.basename[0 .. res.basename_len];
    Inode* new_inode;
    return res.parent.ops.create(res.parent, name, InodeType.Dir, &new_inode);
}

Status vfs_unlink(const(char)[] path, Inode* cwd) {
    auto res = resolve_parent(path, cwd);
    if (res.parent is null)
        return Status.NotFound;
    if (res.parent.ops is null || res.parent.ops.unlink is null)
        return Status.Permission;

    auto name = cast(const(char)[])res.basename[0 .. res.basename_len];
    return res.parent.ops.unlink(res.parent, name);
}

Status vfs_seek(FileDescription fd, i64 offset, SeekWhence whence, u64* new_offset) {
    if (fd is null || fd.inode is null)
        return Status.Inval;

    i64 new_off;
    final switch (whence) {
        case SeekWhence.Set:
            new_off = offset;
            break;
        case SeekWhence.Cur:
            new_off = cast(i64)fd.offset + offset;
            break;
        case SeekWhence.End:
            new_off = cast(i64)fd.inode.size + offset;
            break;
    }

    if (new_off < 0)
        return Status.Inval;

    fd.offset = cast(u64)new_off;
    *new_offset = fd.offset;
    return Status.Ok;
}

FileDescription vfs_dup(FileDescription fd) {
    if (fd is null || fd.inode is null)
        return null;

    auto new_fd = knew!FileDescription(fd.inode, fd.flags);
    if (new_fd !is null)
        new_fd.offset = fd.offset;
    return new_fd;
}

Status vfs_rename(const(char)[] old_path, const(char)[] new_path, Inode* cwd) {
    auto old_res = resolve_parent(old_path, cwd);
    auto new_res = resolve_parent(new_path, cwd);

    if (old_res.parent is null || new_res.parent is null)
        return Status.NotFound;

    // Must be on same filesystem
    if (old_res.parent.sb !is new_res.parent.sb)
        return Status.Inval;

    if (old_res.parent.ops is null || old_res.parent.ops.rename is null)
        return Status.Permission;

    auto old_name = cast(const(char)[])old_res.basename[0 .. old_res.basename_len];
    auto new_name = cast(const(char)[])new_res.basename[0 .. new_res.basename_len];
    return old_res.parent.ops.rename(old_res.parent, old_name, new_res.parent, new_name);
}

Status vfs_truncate(FileDescription fd, u64 size) {
    if (fd is null || fd.inode is null)
        return Status.Inval;
    if (fd.inode.type != InodeType.File)
        return Status.IsDir;
    if (fd.inode.ops is null || fd.inode.ops.truncate is null)
        return Status.Permission;

    return fd.inode.ops.truncate(fd.inode, size);
}

// ─────────────────────────────────────────────────────────────────────────────
// VFS init
// ─────────────────────────────────────────────────────────────────────────────

void vfs_init() {
    import kern.tmpfs;

    auto root_sb = tmpfs_create_sb();
    assert(root_sb !is null, "vfs_init: failed to create root tmpfs");

    vfs_root = root_sb.root;
    klog!"VFS initialized, root inode at 0x%x\n"(cast(ulong)cast(void*)vfs_root);
}
