module mm.aspace;

import mm.heap;
import lib.klog;
import hal.cpu;

private enum rb_color {
    RED, BLACK
}

enum {
    MAP_FIXED = 1,
}

struct vm_area {
    vaddr start;
    vaddr end;

    int   flags;

    vm_area *left;
    vm_area *right;
    vm_area *parent;
    rb_color color;

    char[8] name;
}

struct aspace {
    vm_area *root;

    vaddr   start;
    vaddr   end;

    ulong   num_areas;

    vm_area *
    find( vaddr addr ) {
        auto curr = this.root;

        while( curr ) {
            if( addr >= curr.start && addr < curr.end )
                return curr;
            if( addr < curr.start )
                curr = curr.left;
            else
                curr = curr.right;
        }

        return null;
    }

    bool
    overlaps( vaddr start, vaddr end ) {
        auto curr = this.root;

        while( curr ) {
            if( !(end <= curr.start || start >= curr.end) )
                return true;

            if( start < curr.start )
                curr = curr.left;
            else
                curr = curr.right;
        }

        return false;
    }

    vaddr
    find_free( vaddr length ) {
        auto addr = this.start;
        auto curr = this.root;

        if( !curr )
            return addr;

        // Find lestmost node
        while( curr.left ) {
            curr = curr.left;
        }

        // Try before first VMA
        if( curr.start - this.start >= length )
            return this.start;

        // Try gaps between VMAs
        while( curr ) {
            auto next = curr;

            // Find successor
            if( next.right ) {
                next = next.right;
                while( next.left ) next = next.left;
            } else {
                auto p = next.parent;
                while( p && next == p.right ) {
                    next = p;
                    p = p.parent;
                }
                next = p;
            }

            if( !next ) {
                // Try fter last VMA
                if( this.end - curr.end >= length )
                    return curr.end;
            }

            // Try gap between current and next
            if( next.start - curr.end >= length )
                return curr.end;

            curr = next;
        }

        // no space found
        return 0;
    }

    Status
    map( vaddr addr, ulong length, vaddr *result = null, string name="blank", int flags = 0 ) {
        if( !length )
            return Status.Inval;

        ulong start, end;
        // Align length to page boundaries (assuming 4K pages)
        length = (length + 0xFFF) & ~0xFFF;

        if( flags & MAP_FIXED ) {
            start = addr;
            if( start < this.start || start + length > this.end )
                return Status.Inval;

            if( this.overlaps( start, start + length) )
                return Status.Exist;
        } else {
            if( addr != 0 ) {
                start = addr;
                if( start >= this.start && start+length <= this.end && !this.overlaps(start, start+length) ) {
                    // Hint is valid
                } else {
                    start = this.find_free( length );
                }
            } else {
                start = this.find_free( length );
            }

            if( !start || start + length > this.end )
                return Status.NoMem;
        }

        end = start + length;

        auto vma    = kmalloc!vm_area();
        vma.start   = start;
        vma.end     = end;
        vma.name    = name;

        rb_insert( &this, vma );

        if( result )
            *result = start;

        return Status.Ok;
    }

    Status
    unmap( vaddr addr, ulong length ) {
        if( !length ) return Status.Inval;

        length = (length + 0xFFF) & ~0xFFF;
        auto unmap_start = addr;
        auto unmap_end   = addr + length;

        auto vma = this.root;
        auto stack = kmalloc!(vm_area *)( 64 * vm_area.sizeof );
        auto to_process = kmalloc!(vm_area *)( 64 * vm_area.sizeof );
        auto process_count = 0;

        if( (stack == null) | (to_process == null) )
            kpanic!"[VM] unmap: out of memory";

        scope(exit) kfree( stack );
        scope(exit) kfree( to_process );
        auto stack_ptr = 0;
        auto stack_limit = 64;
        auto process_limit = 64;
        auto curr = this.root;

        while( curr || stack_ptr > 0 ) {
            while( curr ) {
                if( stack_ptr == stack_limit-1 ) {
                    stack = krealloc!(vm_area *)( stack, stack_limit + 64 );
                    if( stack == null ) kpanic!"[VM] unmap: out of memory";
                    stack_limit += 64;
                }

                stack[stack_ptr++] = curr;
                curr = curr.left;
            }

            curr = stack[--stack_ptr];

            if( process_count == process_limit-1 ) {
                to_process = krealloc!(vm_area *)( to_process, process_limit + 64 );
                if( to_process == null ) kpanic!"[VM] unmap: out of memory";
                process_limit += 64;
            }

            // Check if this VMA overlaps with unmap range
            if( !(curr.end <= unmap_start || curr.start >= unmap_end) )
                to_process[process_count++] = curr;

            curr = curr.right;
        }

        klog!"[MM] vm_unmap process count: %i"(process_count);
        if( !process_count ) return Status.NotFound;

        // Process each overlapping VMA
        for( auto i = 0; i < process_count; i++ ) {
            vma = to_process[i];

            // Case 1: Unmap range completely contains VMA
            if( unmap_start <= vma.start && unmap_end >= vma.end ) {
                rb_delete( &this, vma );
                kfree( vma );
            } else if( unmap_start > vma.start && unmap_end < vma.end )  {
                // Case 2: Unmap range is in the middle (split into two VMAs)
                // Create new VMA for the right part
                auto right_vma = kmalloc!vm_area();
                if( !right_vma ) return Status.NoMem;

                klog!"right_vma=0x%x"(right_vma);

                right_vma.start = unmap_end;
                right_vma.end = vma.end;
                right_vma.name = "split";
                //right_vma.prot = vma.prot;
                right_vma.flags = vma.flags;

                // Shrink original VMA to left part
                vma.end = unmap_start;

                // Insert right part into tree
                rb_insert( &this, right_vma );
            } else if( unmap_start <= vma.start && unmap_end < vma.end ) {
                // Case 3: Unmap range overlaps start of VMA
                vma.start = unmap_end;
            } else if( unmap_start > vma.start && unmap_end >= vma.end ) {
                // Case 4: Unmap range overlaps end of VMA
                vma.end = unmap_start;
            }
        }


        return Status.Ok;
    }
}

aspace *
as_create( vaddr start, vaddr end ) {
    auto as  = kmalloc!aspace();
    assert( as, "[VM] as_create: out of memory" );

    as.start = start;
    as.end   = end;
    as.root  = null;

    return as;
}

private vm_area *
rb_grandparent( vm_area *area ) {
    return (area && area.parent) ? area.parent.parent : null;
}

private vm_area *
rb_uncle( vm_area *area ) {
    auto g = rb_grandparent( area );

    if( !g )
        return null;
    return area.parent == g.left ? g.right : g.left;
}

private void
rb_rotate_left( aspace *as, vm_area *n ) {
    auto r = n.right;
    n.right = r.left;

    if( r.left )
        r.left.parent = n;
    r.parent = n.parent;

    if( !n.parent )
        as.root = r;
    else if( n == n.parent.left )
        n.parent.left = r;
    else
        n.parent.right = r;

    r.left = n;
    n.parent = r;
}

private void
rb_rotate_right( aspace *as, vm_area *n ) {
    auto l = n.left;
    n.left = l.right;

    if( l.right)
        l.right.parent = n;
    l.parent = n.parent;

    if( !n.parent )
        as.root = l;
    else if( n == n.parent.right )
        n.parent.right = l;
    else
        n.parent.left = l;

    l.right = n;
    n.parent = l;
}

private void
rb_insert_fixup( aspace *as, vm_area *n ) {
    while( n.parent && n.parent.color == rb_color.RED ) {
        auto u = rb_uncle( n );
        auto g = rb_grandparent( n );

        if( u && u.color == rb_color.RED ) {
            n.parent.color = rb_color.BLACK;
            u.color = rb_color.BLACK;
            g.color = rb_color.RED;
            n = g;
        } else {
            if( n.parent == g.left ) {
                if( n == n.parent.right ) {
                    n = n.parent;
                    rb_rotate_left( as, n );
                }
                n.parent.color = rb_color.BLACK;
                g.color = rb_color.RED;
                rb_rotate_right( as, g );
            } else {
                if( n == n.parent.left ) {
                    n = n.parent;
                    rb_rotate_right( as, n );
                }
                n.parent.color = rb_color.BLACK;
                g.color = rb_color.RED;
                rb_rotate_left( as, g );
            }
        }
    }
    as.root.color = rb_color.BLACK;
}

private void
rb_insert( aspace *as, vm_area *vma ) {
    vm_area *parent = null;
    auto curr = as.root;

    while( curr ) {
        parent = curr;
        if( vma.start < curr.start )
            curr = curr.left;
        else
            curr = curr.right;
    }

    vma.parent = parent;
    vma.color = rb_color.RED;

    if( !parent )
        as.root = vma;
    else if( vma.start < parent.start )
        parent.left = vma;
    else
        parent.right = vma;

    rb_insert_fixup( as, vma );
    as.num_areas++;
}

private vm_area *
rb_minimum( vm_area *n ) {
    while( n && n.left )
        n = n.left;
    return n;
}

private void
rb_transplant( aspace *as, vm_area *u, vm_area *v )  {
    if( !u.parent )
        as.root = v;
    else if( u == u.parent.left )
        u.parent.left = v;
    else
        u.parent.right = v;
    if( v )
        v.parent = u.parent;
}

private void
rb_delete_fixup( aspace *as, vm_area *n, vm_area *parent ) {
    while( n != as.root && (!n || n.color == rb_color.BLACK) ) {
        if( n == parent.left ) {
            auto w = parent.right;
            if( w && w.color == rb_color.RED ) {
                w.color = rb_color.BLACK;
                parent.color = rb_color.RED;
                rb_rotate_left( as, parent );
                w = parent.right;
            }
            if( w && (!w.left || w.left.color == rb_color.BLACK) && (!w.right || w.right.color == rb_color.BLACK) ) {
                w.color = rb_color.RED;
                n = parent;
                parent = n.parent;
            } else {
                if( w && (!w.right || w.right.color == rb_color.BLACK) ) {
                    if( w.left ) w.left.color = rb_color.BLACK;
                    w.color = rb_color.RED;
                    rb_rotate_right( as, w );
                    w  = parent.right;
                }
                if( w ) {
                    w.color = parent.color;
                    if( w.right ) w.right.color = rb_color.BLACK;
                }
                parent.color = rb_color.BLACK;
                rb_rotate_left( as, parent );
                n = as.root;
            }
        } else {
            auto w = parent.left;
            if( w && w.color == rb_color.RED ) {
                w.color = rb_color.BLACK;
                parent.color = rb_color.RED;
                rb_rotate_right( as, parent );
                w = parent.left;
            }
            if( w && !(w.right || w.right.color == rb_color.BLACK) && (!w.left || w.left.color == rb_color.BLACK) ) {
                w.color = rb_color.RED;
                n = parent;
                parent = n.parent;
            } else {
                if( w && (!w.left || w.left.color == rb_color.BLACK) ) {
                    if( w.right ) w.right.color = rb_color.BLACK;
                    w.color = rb_color.RED;
                    rb_rotate_left( as, w );
                    w = parent.left;
                }
                if( w ) {
                    w.color = parent.color;
                    if( w.left ) w.left.color = rb_color.BLACK;
                }
                parent.color = rb_color.BLACK;
                rb_rotate_right( as, parent );
                n = as.root;
            }
        }
    }
    if( n ) n.color = rb_color.BLACK;
}

private void
rb_delete( aspace *as, vm_area *vma ) {
    auto y = vma;
    vm_area *x;
    vm_area *x_parent;
    rb_color orig_color = y.color;

    if( !vma.left ) {
        x = vma.right;
        x_parent = vma.parent;
        rb_transplant( as, vma, vma.right );
    } else if( !vma.right ) {
        x = vma.left;
        x_parent = vma.parent;
        rb_transplant( as, vma, vma.left );
    } else {
        y = rb_minimum( vma.right );
        orig_color = y.color;
        x = y.right;
        if( y.parent == vma ) {
            x_parent = y;
            if( x ) x.parent = y;
        } else {
            x_parent = y.parent;
            rb_transplant( as, y, y.right );
            y.right = vma.right;
            y.right.parent = y;
        }
        rb_transplant( as, vma, y );
        y.left = vma.left;
        y.left.parent = y;
        y.color = vma.color;
    }

    if( orig_color == rb_color.BLACK ) {
        rb_delete_fixup( as, x, x_parent );
    }

    as.num_areas--;
}
