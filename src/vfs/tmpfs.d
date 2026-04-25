module kern.tmpfs;

import lib.klog;
import mm.heap;
import kern.vfs;
import lib.runtime : memset, memcpy;

// ─────────────────────────────────────────────────────────────────────────────
// Per-inode fs_data structures
// ─────────────────────────────────────────────────────────────────────────────

struct TmpfsFileData {
    ubyte* data;
    u64    capacity;
}

struct TmpfsDirChild {
    char[MAX_NAME] name;
    u32            name_len;
    Inode*         inode;
    TmpfsDirChild* next;
}

struct TmpfsDirData {
    TmpfsDirChild* children;
    u32            count;
    Inode*         parent; // ".." target
    Inode*         self;   // "."  target
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

private bool name_eq(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    for (size_t i = 0; i < a.length; i++)
        if (a[i] != b[i]) return false;
    return true;
}

private Inode* alloc_inode(SuperBlock* sb, InodeType type) {
    auto inode = kmalloc!Inode();
    if (inode is null) return null;

    inode.ino      = sb.alloc_ino();
    inode.type     = type;
    inode.nlink    = 1;
    inode.size     = 0;
    inode.refcount = 0;
    inode.sb       = sb;

    if (type == InodeType.File) {
        inode.ops = &tmpfs_file_ops;
        auto fd = kmalloc!TmpfsFileData();
        if (fd is null) { kfree(inode); return null; }
        fd.data = null;
        fd.capacity = 0;
        inode.fs_data = fd;
    } else {
        inode.ops = &tmpfs_dir_ops;
        auto dd = kmalloc!TmpfsDirData();
        if (dd is null) { kfree(inode); return null; }
        dd.children = null;
        dd.count    = 0;
        dd.self     = inode;
        dd.parent   = inode; // default parent is self (root)
        inode.fs_data = dd;
    }

    return inode;
}

// ─────────────────────────────────────────────────────────────────────────────
// File ops
// ─────────────────────────────────────────────────────────────────────────────

Status tmpfs_read(Inode* inode, u64 offset, ubyte* buf, u64 len, u64* bytes_read) {
    auto fd = cast(TmpfsFileData*)inode.fs_data;
    *bytes_read = 0;

    if (offset >= inode.size)
        return Status.Ok; // EOF

    u64 avail = inode.size - offset;
    u64 to_read = len < avail ? len : avail;

    if (to_read > 0 && fd.data !is null)
        memcpy(buf, fd.data + offset, cast(size_t)to_read);

    *bytes_read = to_read;
    return Status.Ok;
}

Status tmpfs_write(Inode* inode, u64 offset, const(ubyte)* buf, u64 len, u64* bytes_written) {
    auto fd = cast(TmpfsFileData*)inode.fs_data;
    *bytes_written = 0;

    u64 end_pos = offset + len;

    // Grow buffer if needed
    if (end_pos > fd.capacity) {
        u64 new_cap = fd.capacity;
        if (new_cap == 0) new_cap = 64;
        while (new_cap < end_pos)
            new_cap *= 2;

        auto new_data = kmalloc!ubyte(cast(size_t)new_cap);
        if (new_data is null)
            return Status.NoMem;

        if (fd.data !is null && inode.size > 0)
            memcpy(new_data, fd.data, cast(size_t)inode.size);

        // Zero-fill gap between old size and new write start
        if (offset > inode.size)
            memset(new_data + inode.size, 0, cast(size_t)(offset - inode.size));

        if (fd.data !is null)
            kfree(fd.data);

        fd.data = new_data;
        fd.capacity = new_cap;
    }

    memcpy(fd.data + offset, buf, cast(size_t)len);

    if (end_pos > inode.size)
        inode.size = end_pos;

    *bytes_written = len;
    return Status.Ok;
}

Status tmpfs_truncate(Inode* inode, u64 size) {
    auto fd = cast(TmpfsFileData*)inode.fs_data;

    if (size == 0) {
        if (fd.data !is null) {
            kfree(fd.data);
            fd.data = null;
        }
        fd.capacity = 0;
        inode.size = 0;
        return Status.Ok;
    }

    if (size > fd.capacity) {
        u64 new_cap = fd.capacity;
        if (new_cap == 0) new_cap = 64;
        while (new_cap < size)
            new_cap *= 2;

        auto new_data = kmalloc!ubyte(cast(size_t)new_cap);
        if (new_data is null)
            return Status.NoMem;

        if (fd.data !is null && inode.size > 0)
            memcpy(new_data, fd.data, cast(size_t)(inode.size < size ? inode.size : size));

        if (size > inode.size)
            memset(new_data + inode.size, 0, cast(size_t)(size - inode.size));

        if (fd.data !is null)
            kfree(fd.data);

        fd.data = new_data;
        fd.capacity = new_cap;
    }

    inode.size = size;
    return Status.Ok;
}

Status tmpfs_file_stat(Inode* inode, VfsStat* st) {
    st.ino   = inode.ino;
    st.size  = inode.size;
    st.type  = inode.type;
    st.nlink = inode.nlink;
    return Status.Ok;
}

// ─────────────────────────────────────────────────────────────────────────────
// Directory ops
// ─────────────────────────────────────────────────────────────────────────────

Inode* tmpfs_lookup(Inode* dir, const(char)[] name) {
    auto dd = cast(TmpfsDirData*)dir.fs_data;

    if (name_eq(name, "."))
        return dd.self;
    if (name_eq(name, ".."))
        return dd.parent;

    auto child = dd.children;
    while (child !is null) {
        if (child.name_len == name.length &&
            name_eq(child.name[0 .. child.name_len], name))
            return child.inode;
        child = child.next;
    }
    return null;
}

Status tmpfs_create(Inode* dir, const(char)[] name, InodeType type, Inode** result) {
    auto dd = cast(TmpfsDirData*)dir.fs_data;

    // Check for existing
    if (tmpfs_lookup(dir, name) !is null)
        return Status.Exist;

    if (name.length == 0 || name.length >= MAX_NAME)
        return Status.Inval;

    auto new_inode = alloc_inode(dir.sb, type);
    if (new_inode is null)
        return Status.NoMem;

    // Set parent for new directories
    if (type == InodeType.Dir) {
        auto new_dd = cast(TmpfsDirData*)new_inode.fs_data;
        new_dd.parent = dir;
    }

    // Link into parent's child list
    auto child = kmalloc!TmpfsDirChild();
    if (child is null) {
        kfree(new_inode.fs_data);
        kfree(new_inode);
        return Status.NoMem;
    }

    child.name[0 .. name.length] = name[];
    child.name_len = cast(u32)name.length;
    child.inode = new_inode;
    child.next = dd.children;
    dd.children = child;
    dd.count++;

    dir.nlink++;
    *result = new_inode;
    return Status.Ok;
}

Status tmpfs_unlink(Inode* dir, const(char)[] name) {
    auto dd = cast(TmpfsDirData*)dir.fs_data;

    TmpfsDirChild* prev = null;
    auto child = dd.children;

    while (child !is null) {
        if (child.name_len == name.length &&
            name_eq(child.name[0 .. child.name_len], name))
        {
            // Check if it's a non-empty directory
            if (child.inode.type == InodeType.Dir) {
                auto child_dd = cast(TmpfsDirData*)child.inode.fs_data;
                if (child_dd.count > 0)
                    return Status.NotEmpty;
            }

            // Unlink
            if (prev !is null)
                prev.next = child.next;
            else
                dd.children = child.next;

            dd.count--;
            child.inode.nlink--;
            // Free inode data if nlink==0 and refcount==0
            if (child.inode.nlink == 0 && child.inode.refcount == 0) {
                if (child.inode.fs_data !is null)
                    kfree(child.inode.fs_data);
                kfree(child.inode);
            }
            kfree(child);
            return Status.Ok;
        }
        prev = child;
        child = child.next;
    }

    return Status.NotFound;
}

Status tmpfs_readdir(Inode* dir, u64 offset, DirEntry* entry, u64* next_offset) {
    auto dd = cast(TmpfsDirData*)dir.fs_data;

    // offset 0 = ".", offset 1 = "..", offset 2+ = children
    if (offset == 0) {
        entry.ino  = dd.self.ino;
        entry.type = InodeType.Dir;
        entry.name[0] = '.';
        entry.name_len = 1;
        *next_offset = 1;
        return Status.Ok;
    }

    if (offset == 1) {
        entry.ino  = dd.parent.ino;
        entry.type = InodeType.Dir;
        entry.name[0] = '.';
        entry.name[1] = '.';
        entry.name_len = 2;
        *next_offset = 2;
        return Status.Ok;
    }

    // Walk to the (offset - 2)th child
    u64 idx = 0;
    auto child = dd.children;
    while (child !is null && idx < offset - 2) {
        child = child.next;
        idx++;
    }

    if (child is null)
        return Status.NotFound; // end of directory

    entry.ino  = child.inode.ino;
    entry.type = child.inode.type;
    entry.name_len = child.name_len;
    entry.name[0 .. child.name_len] = child.name[0 .. child.name_len];
    *next_offset = offset + 1;
    return Status.Ok;
}

Status tmpfs_dir_stat(Inode* inode, VfsStat* st) {
    st.ino   = inode.ino;
    st.size  = 0;
    st.type  = inode.type;
    st.nlink = inode.nlink;
    return Status.Ok;
}

Status tmpfs_rename(Inode* old_dir, const(char)[] old_name,
                    Inode* new_dir, const(char)[] new_name)
{
    // Find the source child
    auto old_dd = cast(TmpfsDirData*)old_dir.fs_data;
    TmpfsDirChild* prev = null;
    auto child = old_dd.children;

    while (child !is null) {
        if (child.name_len == old_name.length &&
            name_eq(child.name[0 .. child.name_len], old_name))
            break;
        prev = child;
        child = child.next;
    }

    if (child is null)
        return Status.NotFound;

    // Check if target exists and unlink it
    auto existing = tmpfs_lookup(new_dir, new_name);
    if (existing !is null) {
        auto st = tmpfs_unlink(new_dir, new_name);
        if (st != Status.Ok)
            return st;
    }

    // Remove from old parent
    if (prev !is null)
        prev.next = child.next;
    else
        old_dd.children = child.next;
    old_dd.count--;

    // Update child name
    child.name[0 .. new_name.length] = new_name[];
    child.name_len = cast(u32)new_name.length;

    // Add to new parent
    auto new_dd = cast(TmpfsDirData*)new_dir.fs_data;
    child.next = new_dd.children;
    new_dd.children = child;
    new_dd.count++;

    // Update parent ref if it's a directory
    if (child.inode.type == InodeType.Dir) {
        auto child_dir_data = cast(TmpfsDirData*)child.inode.fs_data;
        child_dir_data.parent = new_dir;
    }

    return Status.Ok;
}

// ─────────────────────────────────────────────────────────────────────────────
// Op tables
// ─────────────────────────────────────────────────────────────────────────────

__gshared InodeOps tmpfs_file_ops = InodeOps(
    &tmpfs_read,
    &tmpfs_write,
    &tmpfs_truncate,
    null,                // lookup (files don't have children)
    null,                // create
    null,                // unlink
    null,                // readdir
    &tmpfs_file_stat,
    null,                // rename
);

__gshared InodeOps tmpfs_dir_ops = InodeOps(
    null,                // read (dirs don't support read)
    null,                // write
    null,                // truncate
    &tmpfs_lookup,
    &tmpfs_create,
    &tmpfs_unlink,
    &tmpfs_readdir,
    &tmpfs_dir_stat,
    &tmpfs_rename,
);

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

SuperBlock* tmpfs_create_sb() {
    auto sb = kmalloc!SuperBlock();
    if (sb is null) return null;

    sb.next_ino = 1;
    sb.fs_data  = null;

    auto root = alloc_inode(sb, InodeType.Dir);
    if (root is null) {
        kfree(sb);
        return null;
    }

    sb.root = root;
    klog!"tmpfs: created superblock at 0x%x, root inode %d\n"(
        cast(ulong)cast(void*)sb, root.ino);
    return sb;
}

// Create a file inode under a parent directory — used by initrd loader
Inode* tmpfs_create_file(SuperBlock* sb, Inode* parent, const(char)[] name) {
    Inode* result;
    auto st = tmpfs_create(parent, name, InodeType.File, &result);
    if (st != Status.Ok)
        return null;
    return result;
}

// Bulk write data into a file inode — used by initrd loader
Status tmpfs_write_data(Inode* inode, const(ubyte)* data, u64 len, u64 offset) {
    u64 written;
    return tmpfs_write(inode, offset, data, len, &written);
}

// Create a directory inode under a parent — used by initrd loader
Inode* tmpfs_create_dir(SuperBlock* sb, Inode* parent, const(char)[] name) {
    Inode* result;
    auto st = tmpfs_create(parent, name, InodeType.Dir, &result);
    if (st != Status.Ok)
        return null;
    return result;
}
