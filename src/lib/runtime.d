module lib.runtime;

import lib.klog;
import hal.cpu;

pragma(inline, true) {
    ulong
    roundup( ulong n, ulong a )
    {
        return (n + a - 1) & ~(a - 1);
    }
}

ulong
find_highest_bit( ulong mask ) {
    ulong n;

    asm {
        bsr RAX, mask;
        mov n, RAX;
    }
    return n;
}

extern(C) void
_d_array_slice_copy(void* dst, size_t dstlen, void* src, size_t srclen, size_t elemsz)
{
    import ldc.intrinsics : llvm_memcpy;
    llvm_memcpy!size_t(dst, src, dstlen * elemsz, 0);
}


extern(C) {
    void *
    memcpy( void * dest, const void * src, size_t n ) {
        char * d = cast(char *)dest;
        const char * s = cast(const char *)src;
        for( size_t i = 0; i < n; i++ ) {
            d[i] = s[i];
        }
        return dest;
    }

    void *
    memset( void * s, int c, size_t n ) {
        char * p = cast(char *)s;
        for( size_t i = 0; i < n; i++ ) {
            p[i] = cast(char)c;
        }
        return s;
    }

    void
    memzero( void *dest, size_t size ) {
        memset( dest, 0, size );
    }

    void *
    memmove( void * dest, const void * src, size_t n ) {
        char * d = cast(char *)dest;
        const char * s = cast(const char *)src;

        if( d < s ) {
            for( size_t i = 0; i < n; i++ ) {
                d[i] = s[i];
            }
        } else if( d > s ) {
            for( size_t i = n; i != 0; i-- ) {
                d[i - 1] = s[i - 1];
            }
        }

        return dest;
    }

    int
    memcmp( const void * s1, const void * s2, size_t n ) {
        const char * p1 = cast(const char *)s1;
        const char * p2 = cast(const char *)s2;

        for( size_t i = 0; i < n; i++ ) {
            if( p1[i] != p2[i] ) {
                return cast(int)( p1[i] - p2[i] );
            }
        }

        return 0;
    }


    size_t
    strlen( const(char)* s ) {
        size_t n = 0;
        while (s[n] != '\0') n++;
        return n;
    }

    /* strncpy:  copy at most n characters of t to s */
    void
    strncpy( char *s, char *t, int n )
    {
        while( *t && n-- > 0 )
            *s++ = *t++;
        *s = '\0';
    }

    int
    strncmp( char *s1, immutable(char)* s2, size_t n ) {
        char u1, u2;

        while( n-- > 0 ) {
            u1 = *s1++;
            u2 = *s2++;
            if( u1 != u2 )
                return u1 - u2;
            if( u1 == '\0' )
                return 0;
        }
        return 0;
    }

    void
    __assert( string msg, uint line ) {
        kpanic!"Assertion failed: %s:%i\n"( msg.ptr, line );
        hang();
    }

    /*void
    _d_assert( string msg, uint line ) {
        __assert( msg, line );
    }*/

    void
    _Unwind_Resume() {
        klog!"Unwind_resume()";
    }
}
