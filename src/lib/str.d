module lib.str;

import lib.runtime, mm.heap, lib.klog, kern.object;

final class String : KObject {
    enum size_t npos = size_t.max;

private:
    struct IndexProxy {
        String owner;
        size_t index;

        @property char value() const {
            return owner.readIndex(index);
        }

        void opAssign(char ch) {
            owner.opIndexAssign(ch, index);
        }

        alias value this;
    }

    char* _data;
    size_t _storageLength;
    size_t _capacity;
    size_t _start;
    size_t _end;
    char _tailChar;
    bool _hasTailChar;

public:
    this() {
    }

    this(const(char)[] text) {
        assign(text);
    }

    this(const String other) {
        if (other !is null) {
            assign(other);
        }
    }

    ~this() {
        release();
    }

    @property size_t length() const {
        return _end - _start;
    }

    @property size_t fullLength() const {
        return _storageLength;
    }

    @property size_t capacity() const {
        return _capacity;
    }

    @property size_t windowStart() const {
        return _start;
    }

    @property size_t windowEnd() const {
        return _end;
    }

    @property bool empty() const {
        return length == 0;
    }

    @property const(char)* ptr() const {
        return _data is null ? cast(const(char)*)"" : _data + _start;
    }

    @property const(char)[] view() const {
        return _data is null ? null : _data[_start .. _end];
    }

    @property char[] data() {
        return _data is null ? null : _data[_start .. _end];
    }

    override string toString() {
        return cast(string)view;
    }

    String dup() const {
        return new String(this);
    }

    StringWindow window() const {
        return new StringWindow(this);
    }

    String reset() {
        restoreTail();
        _start = 0;
        _end = _storageLength;
        sealWindow();
        return this;
    }

    String advance(size_t count = 1) {
        restoreTail();
        size_t step = count > length ? length : count;
        _start += step;
        sealWindow();
        return this;
    }

    String rewind(size_t count = 1) {
        restoreTail();
        size_t step = count > _start ? _start : count;
        _start -= step;
        sealWindow();
        return this;
    }

    void clear() {
        restoreTail();
        _storageLength = 0;
        _start = 0;
        _end = 0;
        _hasTailChar = false;
        if (_data !is null) {
            _data[0] = '\0';
        }
    }

    void reserve(size_t requested) {
        if (requested > _capacity) {
            growTo(requested);
        }
    }

    void shrinkToFit() {
        if (_storageLength == _capacity) {
            return;
        }

        if (_storageLength == 0) {
            release();
            return;
        }

        auto replacement = allocate(_storageLength);
        copyStorageTo(replacement);
        replacement[_storageLength] = '\0';
        kfree(_data);
        _data = replacement;
        _capacity = _storageLength;
        _hasTailChar = false;
        sealWindow();
    }

    void resize(size_t newLength, char fill = '\0') {
        auto current = length;
        if (newLength < current) {
            erase(newLength, current - newLength);
            return;
        }

        while (current < newLength) {
            append(fill);
            ++current;
        }
    }

    String assign(const(char)[] text) {
        if (overlaps(text)) {
            auto copy = new String(text);
            return assign(copy.view);
        }

        restoreTail();
        reserve(text.length);
        if (text.length != 0) {
            copyInto(_data, text.ptr, text.length);
        }

        _storageLength = text.length;
        _start = 0;
        _end = text.length;

        if (_data !is null) {
            _data[_storageLength] = '\0';
        }
        _hasTailChar = false;
        sealWindow();
        return this;
    }

    String assign(const String other) {
        if (other is null) {
            clear();
            return this;
        }

        if (other is this) {
            return this;
        }

        reserve(other._storageLength);
        copyStorageFrom(other);
        _storageLength = other._storageLength;
        _start = other._start;
        _end = other._end;

        if (_data !is null) {
            _data[_storageLength] = '\0';
        }
        _hasTailChar = false;
        sealWindow();
        return this;
    }

    String append(char ch) {
        char[1] one = [ch];
        return replaceRange(length, 0, one[]);
    }

    String append(const(char)[] text) {
        return replaceRange(length, 0, text);
    }

    String append(const String other) {
        if (other is null) {
            return this;
        }
        return append(other.view);
    }

    String append(const StringWindow other) {
        if (other is null) {
            return this;
        }
        return append(other.view);
    }

    String append(T)(T value) if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            return appendSigned(cast(long)value);
        } else {
            return appendUnsigned(cast(ulong)value);
        }
    }

    String insert(size_t index, const(char)[] text) {
        return replaceRange(index, 0, text);
    }

    String insert(size_t index, const String text) {
        return insert(index, text is null ? null : text.view);
    }

    String erase(size_t index, size_t count = 1) {
        return replaceRange(index, count, null);
    }

    String replaceAll(const(char)[] needle, const(char)[] replacement) {
        if (needle.length == 0) {
            return this;
        }

        auto result = new String;
        size_t cursor = 0;
        auto currentView = view;

        while (cursor < currentView.length) {
            auto at = indexOf(needle, cursor);
            if (at == npos) {
                result.append(currentView[cursor .. $]);
                break;
            }

            result.append(currentView[cursor .. at]);
            result.append(replacement);
            cursor = at + needle.length;
        }

        return replaceRange(0, length, result.view);
    }

    String substring(size_t start, size_t count = npos) const {
        boundsCheckInsert(start);

        size_t available = length - start;
        if (count == npos || count > available) {
            count = available;
        }

        auto currentView = view;
        return new String(currentView[start .. start + count]);
    }

    size_t indexOf(char needle, size_t start = 0) const {
        if (start >= length) {
            return npos;
        }

        auto base = activePtr();
        for (size_t i = start; i < length; ++i) {
            if (base[i] == needle) {
                return i;
            }
        }

        return npos;
    }

    size_t indexOf(const(char)[] needle, size_t start = 0) const {
        auto currentLength = length;
        if (needle.length == 0) {
            return start <= currentLength ? start : npos;
        }

        if (needle.length > currentLength) {
            return npos;
        }

        if (start > currentLength - needle.length) {
            return npos;
        }

        for (size_t i = start; i <= currentLength - needle.length; ++i) {
            if (matchesAt(i, needle)) {
                return i;
            }
        }

        return npos;
    }

    size_t lastIndexOf(char needle) const {
        auto base = activePtr();
        for (size_t i = length; i > 0; --i) {
            if (base[i - 1] == needle) {
                return i - 1;
            }
        }

        return npos;
    }

    bool contains(char needle) const {
        return indexOf(needle) != npos;
    }

    bool contains(const(char)[] needle) const {
        return indexOf(needle) != npos;
    }

    bool startsWith(const(char)[] prefix) const {
        return prefix.length <= length && equalBytes(activePtr(), prefix.ptr, prefix.length);
    }

    bool endsWith(const(char)[] suffix) const {
        auto currentLength = length;
        return suffix.length <= currentLength &&
            equalBytes(activePtr() + (currentLength - suffix.length), suffix.ptr, suffix.length);
    }

    String trimAscii() {
        restoreTail();

        while (_start < _end && isAsciiSpace(_data[_start])) {
            ++_start;
        }

        while (_end > _start && isAsciiSpace(_data[_end - 1])) {
            --_end;
        }

        sealWindow();
        return this;
    }

    String toLowerAscii() {
        auto base = activePtr();
        for (size_t i = 0; i < length; ++i) {
            if (base[i] >= 'A' && base[i] <= 'Z') {
                base[i] = cast(char)(base[i] + ('a' - 'A'));
            }
        }
        return this;
    }

    String toUpperAscii() {
        auto base = activePtr();
        for (size_t i = 0; i < length; ++i) {
            if (base[i] >= 'a' && base[i] <= 'z') {
                base[i] = cast(char)(base[i] - ('a' - 'A'));
            }
        }
        return this;
    }

    int compare(const(char)[] rhs) const {
        auto currentLength = length;
        size_t common = currentLength < rhs.length ? currentLength : rhs.length;
        if (common != 0) {
            int cmp = memcmp(activePtr(), rhs.ptr, common);
            if (cmp < 0) {
                return -1;
            }
            if (cmp > 0) {
                return 1;
            }
        }

        if (currentLength < rhs.length) {
            return -1;
        }
        if (currentLength > rhs.length) {
            return 1;
        }
        return 0;
    }

    int compare(const String rhs) const {
        if (rhs is null) {
            return length == 0 ? 0 : 1;
        }
        return compare(rhs.view);
    }

    int compare(const StringWindow rhs) const {
        if (rhs is null) {
            return length == 0 ? 0 : 1;
        }
        return compare(rhs.view);
    }

    IndexProxy opIndex(size_t index) {
        return IndexProxy(this, index);
    }

    char opIndexAssign(char value, size_t index) {
        if (index >= length) {
            resize(index + 1);
        }
        activePtr()[index] = value;
        return value;
    }

    char opIndex(size_t index) const {
        return readIndex(index);
    }

    const(char)[] opSlice(size_t start, size_t end) const {
        if (start > end || end > length) {
            kpanic!"opSlice out of bounds";
        }
        return activePtr()[start .. end];
    }

    override bool opEquals(const Object rhs) const {
        auto other = cast(const String)rhs;
        return other !is null && compare(other.view) == 0;
    }

    bool opEquals(const(char)[] rhs) const {
        return compare(rhs) == 0;
    }

    bool opEquals(const StringWindow rhs) const {
        return compare(rhs) == 0;
    }

    override int opCmp(const Object rhs) const {
        auto other = cast(const String)rhs;
        if (other is null) {
            return 1;
        }
        return compare(other.view);
    }

    String opUnary(string op)()
        if (op == "++" || op == "--") {
        static if (op == "++") {
            return advance(1);
        } else {
            return rewind(1);
        }
    }

    String opBinary(string op, T)(T rhs) const
        if ((op == "~" || op == "+") && isAppendable!T) {
        auto result = dup();
        result.appendValue(rhs);
        return result;
    }

    String opBinary(string op, T)(T rhs) const
        if ((op == "<<" || op == ">>") && isIntegral!T) {
        auto result = dup();
        static if (op == "<<") {
            result.advance(cast(size_t)rhs);
        } else {
            result.rewind(cast(size_t)rhs);
        }
        return result;
    }

    String opBinaryRight(string op)(const(char)[] lhs) const
        if (op == "~" || op == "+") {
        auto result = new String(lhs);
        result.append(view);
        return result;
    }

    String opOpAssign(string op, T)(T rhs)
        if ((op == "~" && isAppendable!T) ||
            (op == "+" && isAppendable!T && !isIntegral!T)) {
        return appendValue(rhs);
    }

    String opOpAssign(string op, T)(T rhs)
        if (op == "+" && isIntegral!T) {
        return advance(cast(size_t)rhs);
    }

    String opOpAssign(string op, T)(T rhs)
        if ((op == "<<" || op == ">>") && isIntegral!T) {
        static if (op == "<<") {
            return advance(cast(size_t)rhs);
        } else {
            return rewind(cast(size_t)rhs);
        }
    }

private:
    char readIndex(size_t index) const {
        if (index > length) {
            kpanic!"String bounds check index";
        }
        return activePtr()[index];
    }

    const(char)* activePtr() const {
        return _data is null ? cast(const(char)*)"" : _data + _start;
    }

    char* activePtr() {
        return _data is null ? null : _data + _start;
    }

    void release() {
        if (_data !is null) {
            kfree(_data);
            _data = null;
        }
        _storageLength = 0;
        _capacity = 0;
        _start = 0;
        _end = 0;
        _tailChar = 0;
        _hasTailChar = false;
    }

    bool overlaps(const(char)[] text) const {
        if (_data is null || text.length == 0) {
            return false;
        }

        auto start = cast(const(char)*)_data;
        auto finish = start + _storageLength;
        auto other = text.ptr;
        return other >= start && other < finish;
    }

    bool matchesAt(size_t index, const(char)[] needle) const {
        return equalBytes(activePtr() + index, needle.ptr, needle.length);
    }

    void growTo(size_t requested) {
        size_t newCapacity = _capacity == 0 ? 16 : _capacity;
        while (newCapacity < requested) {
            if (newCapacity > size_t.max / 2) {
                newCapacity = requested;
                break;
            }
            newCapacity *= 2;
        }

        auto replacement = allocate(newCapacity);
        copyStorageTo(replacement);
        replacement[_storageLength] = '\0';

        if (_data !is null) {
            kfree(_data);
        }
        _data = replacement;
        _capacity = newCapacity;
        _hasTailChar = false;
    }

    char* allocate(size_t capacity) {
        auto buffer = kmalloc!char(capacity + 1);
        if (buffer is null) {
            kpanic!"String allocation got a null pointer";
        }
        return buffer;
    }

    void boundsCheckIndex(size_t index) const {
        if (index >= length) {
            kpanic!"String bounds check index";
        }
    }

    void boundsCheckInsert(size_t index) const {
        if (index > length) {
            kpanic!"String bounds check insert";
        }
    }

    String replaceRange(size_t index, size_t count, const(char)[] replacement) {
        boundsCheckInsert(index);
        auto currentLength = length;
        if (count > currentLength - index) {
            count = currentLength - index;
        }

        if (overlaps(replacement)) {
            auto copy = new String(replacement);
            return replaceRange(index, count, copy.view);
        }

        restoreTail();

        auto absoluteIndex = _start + index;
        auto tailSource = absoluteIndex + count;
        auto tailCount = _storageLength - tailSource;
        auto replacementLength = replacement.length;
        auto newStorageLength = _storageLength - count + replacementLength;

        reserve(newStorageLength);

        if (tailCount != 0 && replacementLength != count) {
            moveBytes(_data + absoluteIndex + replacementLength, _data + tailSource, tailCount);
        }

        if (replacementLength != 0) {
            copyInto(_data + absoluteIndex, replacement.ptr, replacementLength);
        }

        _storageLength = newStorageLength;
        _end = _end - count + replacementLength;
        _data[_storageLength] = '\0';
        _hasTailChar = false;
        sealWindow();
        return this;
    }

    void copyStorageTo(char* dst) const {
        if (_storageLength == 0) {
            return;
        }

        if (!_hasTailChar) {
            copyInto(dst, _data, _storageLength);
            return;
        }

        if (_end != 0) {
            copyInto(dst, _data, _end);
        }

        dst[_end] = _tailChar;

        auto suffixStart = _end + 1;
        if (suffixStart < _storageLength) {
            copyInto(dst + suffixStart, _data + suffixStart, _storageLength - suffixStart);
        }
    }

    void copyStorageFrom(const String other) {
        if (other._storageLength == 0) {
            return;
        }

        if (!other._hasTailChar) {
            copyInto(_data, other._data, other._storageLength);
            return;
        }

        if (other._end != 0) {
            copyInto(_data, other._data, other._end);
        }

        _data[other._end] = other._tailChar;

        auto suffixStart = other._end + 1;
        if (suffixStart < other._storageLength) {
            copyInto(_data + suffixStart, other._data + suffixStart, other._storageLength - suffixStart);
        }
    }

    void restoreTail() {
        if (_hasTailChar && _data !is null) {
            _data[_end] = _tailChar;
            _hasTailChar = false;
        }
    }

    void sealWindow() {
        if (_data is null) {
            _hasTailChar = false;
            return;
        }

        if (_end < _storageLength) {
            _tailChar = _data[_end];
            _data[_end] = '\0';
            _hasTailChar = true;
        } else {
            _data[_storageLength] = '\0';
            _hasTailChar = false;
        }
    }

    String appendValue(T)(T rhs) if (isAppendable!T) {
        static if (is(T == char)) {
            return append(rhs);
        } else static if (is(T : const(char)[])) {
            return append(rhs);
        } else static if (is(T : String)) {
            return append(rhs);
        } else static if (isIntegral!T) {
            return append(rhs);
        }
    }

    String appendUnsigned(ulong value) {
        char[32] buffer;
        size_t cursor = buffer.length;

        do {
            buffer[--cursor] = cast(char)('0' + (value % 10));
            value /= 10;
        } while (value != 0);

        return append(buffer[cursor .. $]);
    }

    String appendSigned(long value) {
        if (value < 0) {
            append('-');
            auto magnitude = cast(ulong)(-(value + 1)) + 1;
            return appendUnsigned(magnitude);
        }

        return appendUnsigned(cast(ulong)value);
    }

    static bool isAsciiSpace(char ch) {
        return ch == ' ' || (ch >= '\t' && ch <= '\r');
    }

    static bool equalBytes(const(char)* lhs, const(char)* rhs, size_t count) {
        return count == 0 || memcmp(lhs, rhs, count) == 0;
    }

    static void copyInto(char* dst, const(char)* src, size_t count) {
        if (count != 0) {
            memcpy(dst, src, count);
        }
    }

    static void moveBytes(char* dst, const(char)* src, size_t count) {
        if (count != 0) {
            memmove(dst, src, count);
        }
    }
}

final class StringWindow : KObject {
    enum size_t npos = String.npos;

private:
    struct IndexProxy {
        StringWindow owner;
        long index;

        @property char value() const {
            return owner.readRelativeIndex(index);
        }

        void opAssign(char ch) {
            owner.writeRelativeIndex(ch, index);
        }

        alias value this;
    }

    String _string;

public:
    this() {
        _string = new String;
    }

    this(const(char)[] text) {
        _string = new String(text);
    }

    this(const String source) {
        _string = source is null ? new String : new String(source);
    }

    this(const StringWindow other) {
        _string = (other is null || other._string is null) ? new String : new String(other._string);
    }

    @property size_t length() const {
        return _string.length;
    }

    @property size_t fullLength() const {
        return _string.fullLength;
    }

    @property size_t capacity() const {
        return _string.capacity;
    }

    @property size_t windowStart() const {
        return _string.windowStart;
    }

    @property size_t windowEnd() const {
        return _string.windowEnd;
    }

    @property bool empty() const {
        return _string.empty;
    }

    @property const(char)* ptr() const {
        return _string.ptr;
    }

    @property const(char)[] view() const {
        return _string.view;
    }

    @property char[] data() {
        return _string.data;
    }

    override string toString() {
        return cast(string)view;
    }

    String snapshot() const {
        return new String(_string);
    }

    StringWindow dup() const {
        return new StringWindow(this);
    }

    StringWindow reset() {
        _string.reset();
        return this;
    }

    StringWindow advance() {
        _string.advance(1);
        return this;
    }

    StringWindow advance(T)(T count)
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            if (count < 0) {
                _string.rewind(cast(size_t)(-count));
                return this;
            }
        }

        _string.advance(cast(size_t)count);
        return this;
    }

    StringWindow rewind() {
        _string.rewind(1);
        return this;
    }

    StringWindow rewind(T)(T count)
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            if (count < 0) {
                _string.advance(cast(size_t)(-count));
                return this;
            }
        }

        _string.rewind(cast(size_t)count);
        return this;
    }

    void clear() {
        _string.clear();
    }

    void reserve(size_t requested) {
        _string.reserve(requested);
    }

    void shrinkToFit() {
        _string.shrinkToFit();
    }

    void resize(size_t newLength, char fill = '\0') {
        _string.resize(newLength, fill);
    }

    StringWindow assign(const(char)[] text) {
        _string.assign(text);
        return this;
    }

    StringWindow assign(const String other) {
        _string.assign(other);
        return this;
    }

    StringWindow assign(const StringWindow other) {
        if (other is null) {
            _string.clear();
            return this;
        }

        _string.assign(other._string);
        return this;
    }

    StringWindow append(char ch) {
        _string.append(ch);
        return this;
    }

    StringWindow append(const(char)[] text) {
        _string.append(text);
        return this;
    }

    StringWindow append(const String other) {
        _string.append(other);
        return this;
    }

    StringWindow append(const StringWindow other) {
        if (other is null) {
            return this;
        }

        _string.append(other.view);
        return this;
    }

    StringWindow append(T)(T value) if (isIntegral!T) {
        _string.append(value);
        return this;
    }

    StringWindow insert(T)(T index, const(char)[] text)
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            _string.insert(normalizeInsertIndex(index), text);
        } else {
            _string.insert(cast(size_t)index, text);
        }
        return this;
    }

    StringWindow insert(T)(T index, const String text)
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            _string.insert(normalizeInsertIndex(index), text);
        } else {
            _string.insert(cast(size_t)index, text);
        }
        return this;
    }

    StringWindow insert(T)(T index, const StringWindow text)
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            _string.insert(normalizeInsertIndex(index), text is null ? null : text.view);
        } else {
            _string.insert(cast(size_t)index, text is null ? null : text.view);
        }
        return this;
    }

    StringWindow erase(T)(T index, size_t count = 1)
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            _string.erase(normalizeIndex(index), count);
        } else {
            _string.erase(cast(size_t)index, count);
        }
        return this;
    }

    StringWindow replaceAll(const(char)[] needle, const(char)[] replacement) {
        _string.replaceAll(needle, replacement);
        return this;
    }

    StringWindow substring(T)(T start, size_t count = npos) const
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            return new StringWindow(_string.substring(normalizeSliceBound(start), count));
        } else {
            return new StringWindow(_string.substring(cast(size_t)start, count));
        }
    }

    size_t indexOf(char needle, size_t start = 0) const {
        return _string.indexOf(needle, start);
    }

    size_t indexOf(const(char)[] needle, size_t start = 0) const {
        return _string.indexOf(needle, start);
    }

    size_t lastIndexOf(char needle) const {
        return _string.lastIndexOf(needle);
    }

    bool contains(char needle) const {
        return _string.contains(needle);
    }

    bool contains(const(char)[] needle) const {
        return _string.contains(needle);
    }

    bool startsWith(const(char)[] prefix) const {
        return _string.startsWith(prefix);
    }

    bool endsWith(const(char)[] suffix) const {
        return _string.endsWith(suffix);
    }

    StringWindow trimAscii() {
        _string.trimAscii();
        return this;
    }

    StringWindow toLowerAscii() {
        _string.toLowerAscii();
        return this;
    }

    StringWindow toUpperAscii() {
        _string.toUpperAscii();
        return this;
    }

    int compare(const(char)[] rhs) const {
        return _string.compare(rhs);
    }

    int compare(const String rhs) const {
        return _string.compare(rhs);
    }

    int compare(const StringWindow rhs) const {
        if (rhs is null) {
            return length == 0 ? 0 : 1;
        }
        return _string.compare(rhs.view);
    }

    IndexProxy opIndex(T)(T index)
        if (isIntegral!T) {
        return IndexProxy(this, cast(long)index);
    }

    char opIndexAssign(T)(char value, T index)
        if (isIntegral!T) {
        return writeRelativeIndex(value, cast(long)index);
    }

    char opIndex(T)(T index) const
        if (isIntegral!T) {
        static if (isSignedIntegral!T) {
            if (index < 0) {
                return _string._data[normalizeBackIndex(index)];
            }
            return _string[cast(size_t)index];
        } else {
            return _string[cast(size_t)index];
        }
    }

    const(char)[] opSlice(TStart, TEnd)(TStart start, TEnd end) const
        if (isIntegral!TStart && isIntegral!TEnd) {
        auto absoluteStart = normalizeRelativeBound(start);
        auto absoluteEnd = normalizeRelativeBound(end);
        if (absoluteStart > absoluteEnd) {
            kpanic!"StringWindow slice index out of bounds";
        }
        return _string._data[absoluteStart .. absoluteEnd];
    }

    override bool opEquals(const Object rhs) const {
        auto other = cast(const StringWindow)rhs;
        return other !is null && compare(other) == 0;
    }

    bool opEquals(const(char)[] rhs) const {
        return compare(rhs) == 0;
    }

    bool opEquals(const String rhs) const {
        return compare(rhs) == 0;
    }

    bool opEquals(const StringWindow rhs) const {
        return compare(rhs) == 0;
    }

    int opCmp(const StringWindow rhs) const {
        return compare(rhs);
    }

    override int opCmp(const Object rhs) const {
        auto other = cast(const StringWindow)rhs;
        if (other is null) {
            return 1;
        }
        return compare(other);
    }

    StringWindow opUnary(string op)()
        if (op == "++" || op == "--") {
        static if (op == "++") {
            return advance(1);
        } else {
            return rewind(1);
        }
    }

    StringWindow opBinary(string op, T)(T rhs) const
        if ((op == "~" || op == "+") && isAppendable!T) {
        auto result = dup();
        result.appendValue(rhs);
        return result;
    }

    StringWindow opBinary(string op, T)(T rhs) const
        if ((op == "<<" || op == ">>") && isIntegral!T) {
        auto result = dup();
        static if (isSignedIntegral!T) {
            static if (op == "<<") {
                result.advance(rhs);
            } else {
                result.rewind(rhs);
            }
        } else {
            static if (op == "<<") {
                result.advance(cast(size_t)rhs);
            } else {
                result.rewind(cast(size_t)rhs);
            }
        }
        return result;
    }

    StringWindow opBinaryRight(string op)(const(char)[] lhs) const
        if (op == "~" || op == "+") {
        auto result = new StringWindow(lhs);
        result.append(view);
        return result;
    }

    StringWindow opOpAssign(string op, T)(T rhs)
        if ((op == "~" && isAppendable!T) ||
            (op == "+" && isAppendable!T && !isIntegral!T)) {
        return appendValue(rhs);
    }

    StringWindow opOpAssign(string op, T)(T rhs)
        if ((op == "+" || op == "-") && isIntegral!T) {
        static if (op == "+") {
            static if (isSignedIntegral!T) {
                return advance(rhs);
            } else {
                return advance(cast(size_t)rhs);
            }
        } else {
            static if (isSignedIntegral!T) {
                return rewind(rhs);
            } else {
                return rewind(cast(size_t)rhs);
            }
        }
    }

    StringWindow opOpAssign(string op, T)(T rhs)
        if ((op == "<<" || op == ">>") && isIntegral!T) {
        static if (isSignedIntegral!T) {
            static if (op == "<<") {
                return advance(rhs);
            } else {
                return rewind(rhs);
            }
        } else {
            static if (op == "<<") {
                return advance(cast(size_t)rhs);
            } else {
                return rewind(cast(size_t)rhs);
            }
        }
    }

private:
    char readRelativeIndex(long index) const {
        if (index < 0) {
            return _string._data[normalizeBackIndex(index)];
        }

        return _string.readIndex(cast(size_t)index);
    }

    char writeRelativeIndex(char value, long index) {
        if (index < 0) {
            auto absolute = normalizeBackIndex(index);
            _string._data[absolute] = value;
            return value;
        }

        return _string.opIndexAssign(value, cast(size_t)index);
    }

    size_t normalizeBackIndex(T)(T index) const
        if (isSignedIntegral!T) {
        auto normalized = cast(long)index;
        auto currentStart = cast(long)windowStart;
        auto currentEnd = cast(long)windowEnd;

        if (normalized >= 0) {
            kpanic!"StringWindow negative index expected";
        }

        auto absolute = currentStart + normalized;
        if (absolute < 0 || absolute >= currentEnd) {
            kpanic!"StringWindow index out of bounds";
        }

        return cast(size_t)absolute;
    }

    size_t normalizeInsertIndex(T)(T index) const
        if (isSignedIntegral!T) {
        auto normalized = cast(long)index;
        auto currentLength = cast(long)length;

        if (normalized < 0) {
            normalized += currentLength;
        }

        if (normalized < 0 || normalized > currentLength) {
            kpanic!"StringWindow insert index out of bounds";
        }

        return cast(size_t)normalized;
    }

    size_t normalizeRelativeBound(T)(T index) const {
        static if (isSignedIntegral!T) {
            auto normalized = cast(long)index;
            auto absolute = cast(long)windowStart + normalized;
            auto currentEnd = cast(long)windowEnd;

            if (absolute < 0 || absolute > currentEnd) {
                kpanic!"StringWindow slice index out of bounds";
            }

            return cast(size_t)absolute;
        } else static if (isIntegral!T) {
            auto absolute = windowStart + cast(size_t)index;
            if (absolute > windowEnd) {
                kpanic!"StringWindow slice index out of bounds";
            }
            return absolute;
        } else {
            static assert(false, "Unsupported slice index type");
        }
    }

    StringWindow appendValue(T)(T rhs) if (isAppendable!T) {
        static if (is(T == char)) {
            return append(rhs);
        } else static if (is(T : const(char)[])) {
            return append(rhs);
        } else static if (is(T : StringWindow)) {
            return append(rhs);
        } else static if (is(T : String)) {
            return append(rhs);
        } else static if (isIntegral!T) {
            return append(rhs);
        }
    }
}

template isIntegral(T) {
    enum bool isIntegral =
        is(T == byte)  || is(T == ubyte) ||
        is(T == short) || is(T == ushort) ||
        is(T == int)   || is(T == uint) ||
        is(T == long)  || is(T == ulong);
}

template isSignedIntegral(T) {
    enum bool isSignedIntegral =
        is(T == byte) ||
        is(T == short) ||
        is(T == int) ||
        is(T == long);
}

template isAppendable(T) {
    enum bool isAppendable =
        is(T == char) ||
        is(T : const(char)[]) ||
        is(T : StringWindow) ||
        is(T : String) ||
        isIntegral!T;
}

void string_test() {
    auto grow = new String;
    grow[0] = 't';
    grow[2] = 'z';
    assert(grow.length == 3);
    assert(grow[0] == 't');
    assert(grow[1] == '\0');
    assert(grow[2] == 'z');

    auto growWindow = (new String).window();
    growWindow[0] = '/';
    assert(growWindow.compare("/") == 0);

    auto s = new String("  bare metal  ");
    s.trimAscii();
    assert(s.compare("bare metal") == 0);
    s.reset();
    assert(s.compare("  bare metal  ") == 0);

    auto scan = new String("token1,token2");
    scan <<= 6;
    assert(scan.compare(",token2") == 0);
    ++scan;
    assert(scan.compare("token2") == 0);
    --scan;
    assert(scan.compare(",token2") == 0);
    scan.reset();
    assert(scan.compare("token1,token2") == 0);

    auto shifted = scan << 7;
    assert(scan.compare("token1,token2") == 0);
    assert(shifted.compare("token2") == 0);

    scan.insert(6, " ");
    assert(scan.compare("token1 ,token2") == 0);
    scan.erase(6, 2);
    assert(scan.compare("token1token2") == 0);
    scan.reset();
    assert(scan.compare("token1token2") == 0);

    auto joined = shifted + "!";
    assert(joined.compare("token2!") == 0);

    auto hello = new String("Hello");
    hello += 2;
    assert(hello.compare("llo") == 0);

    auto digits = new String("Value: ");
    digits ~= 42;
    assert(digits.compare("Value: 42") == 0);

    auto source = new String("  window layer  ");
    auto win = source.window();
    auto baseline = source.window();
    baseline.trimAscii();
    win.trimAscii();
    win += 2;
    assert(win.compare("ndow layer") == 0);
    assert(source.compare("  window layer  ") == 0);

    auto winShifted = win << 5;
    assert(win.compare("ndow layer") == 0);
    assert(winShifted.compare("layer") == 0);
    assert(source.compare("  window layer  ") == 0);

    assert(win[-1] == 'i');
    assert(win[-2] == 'w');
    assert(win[-2 .. 2] == "wind");

    win += -2;
    assert(win.compare("window layer") == 0);
    win <<= -2;
    assert(win.compare("  window layer") == 0);
    win <<= 2;
    assert(win.compare("window layer") == 0);
    win <<= 2;
    assert(win.compare("ndow layer") == 0);
    assert(win < baseline);
    assert(source.compare("  window layer  ") == 0);

    auto exclaimed = win + "!";
    assert(exclaimed.compare("ndow layer!") == 0);
    assert(win.compare("ndow layer") == 0);
    assert(source.compare("  window layer  ") == 0);

    klog!"Comparison: %i"(win == "ndow layer");

    auto str = new String("/home/nix/test.txt");
    auto pathWindow = str.window();
    pathWindow += 5;
    assert(pathWindow[-1] == 'e');
    assert(pathWindow[-1 .. 3] == "e/ni");

    klog!"<bg:red>String test completed!</>";

    auto STR = new String( "A String!" );
    klog!"%S"(STR);

    klog!"STR length initially is %i"(STR.length);
    STR+=2;
    klog!"Length after incrementing is %i"(STR.length);

    while( true ) {}
}
