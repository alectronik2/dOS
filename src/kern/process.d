module kern.process;

import kern.object, kern.thread, kern.vfs;

class Process : KObject {
    string name;

    ulong  pml4;

    Thread threads;

    Inode* cwd;  // current working directory (VFS inode)
}

__gshared Process kernel_process;

void
process_init() {
    kernel_process = new Process();
    kernel_process.name = "kernel";
}
