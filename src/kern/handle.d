module kern.handle;

import mm.pfdb;

struct Handle {
    void* addr;
}

__gshared {
    Handle* htab;
    Handle* hfreelist;
    int     htabsize;
}

private Status
expand_htab() {
    if( htabsize == HTABSIZE / KObject.sizeof ) return Status.OutOfHandles;
    auto pfn = alloc_pageframe( PageFrameType.HandleTab );
}
