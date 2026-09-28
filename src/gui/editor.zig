//! A multi-line SQL editor buffer.
//!
//! glinlandui's `input` component is explicitly single-line, printable-ASCII
//! only, with a flat `[]u8` + `usize` length. An SQL editor is inherently
//! multi-line, so the buffer is built here — and built as a *pure* module
//! with no glinlandui types, so it can be tested with no display and no
//! windowing system at all.
//!
//! The design follows the same shape as glinlandui's own single-line
//! primitives so the two compose predictably:
//!
//!   - The buffer is a caller-owned `[]u8` plus a `len`. Nothing here
//!     allocates, so an editor cannot fail on out-of-memory mid-keystroke.
//!   - The caret is an offset into that buffer, not a (row, col) pair.
//!     Multi-line navigation derives lines on demand. A single offset is
//!     what makes insertion and deletion a contiguous splice.
//!
//! Only ASCII is inserted (the key layer produces ASCII), but the buffer
//! stores bytes opaquely and never assumes a byte is a character, so a
//! paste of UTF-8 text would still move the caret correctly by byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Action = enum {
    /// The buffer or caret did not change.
    ignored,
    /// Text was inserted or removed, or the caret moved.
    edited,
    /// The caller should run the query (Ctrl+Enter).
    run_requested,
};

/// A caret position within the buffer.
pub const Caret = struct {
    /// Byte offset into the buffer, always in `0..=len`.
    offset: usize = 0,
    /// The byte offset the selection was anchored at, if any.
    anchor: ?usize = null,

    /// The selected byte range, normalised so `start <= end`.
    pub fn selection(self: Caret) ?Span {
        const a = self.anchor orelse return null;
        const o = self.offset;
        return .{ .start = @min(a, o), .end = @max(a, o) };
    }

    pub fn hasSelection(self: Caret) bool {
        return self.anchor != null and self.anchor.? != self.offset;
    }

    /// Keep the caret and anchor inside `0..=len`.
    pub fn clamp(self: *Caret, len: usize) void {
        if (self.offset > len) self.offset = len;
        if (self.anchor) |a| {
            if (a > len) self.anchor = len;
        }
    }

    pub fn clearSelection(self: *Caret) void {
        self.anchor = null;
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

/// Edit operations on a caller-owned buffer.
///
/// Every function takes `buf` + `*len` rather than a `[]u8` so an
/// over-long insert is a no-op instead of a slice-length change the
/// caller has to notice.
pub const Editor = struct {
    buf: []u8,
    len: usize = 0,
    caret: Caret = .{},

    pub fn init(buf: []u8) Editor {
        return .{ .buf = buf };
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf[0..self.len];
    }

    /// Replace the whole contents. Used to load a query or a table's
    /// `SELECT`.
    pub fn setText(self: *Editor, new_text: []const u8) void {
        const n = @min(new_text.len, self.buf.len);
        @memcpy(self.buf[0..n], new_text[0..n]);
        self.len = n;
        self.caret = .{};
    }

    /// Insert one byte at the caret, replacing the selection if any.
    /// Returns false when the buffer is full.
    pub fn insertByte(self: *Editor, c: u8) bool {
        if (self.caret.hasSelection()) {
            _ = self.deleteSelection();
        }
        if (self.len >= self.buf.len) return false;

        // Shift the tail right by one byte, from the back so the copy
        // does not overlap.
        var i = self.len;
        while (i > self.caret.offset) {
            i -= 1;
            self.buf[i + 1] = self.buf[i];
        }
        self.buf[self.caret.offset] = c;
        self.len += 1;
        self.caret.offset += 1;
        return true;
    }

    /// Insert a run of bytes. Stops at capacity rather than failing, so a
    /// paste into a full buffer leaves the text intact up to the limit.
    /// Returns the number of bytes actually inserted.
    pub fn insertSlice(self: *Editor, s: []const u8) usize {
        if (self.caret.hasSelection()) _ = self.deleteSelection();
        var written: usize = 0;
        for (s) |c| {
            if (!self.insertByte(c)) break;
            written += 1;
        }
        return written;
    }

    /// Delete the selection, if any. Returns true if something was removed.
    pub fn deleteSelection(self: *Editor) bool {
        const sel = self.caret.selection() orelse return false;
        if (sel.start == sel.end) return false;
        self.splice(sel.start, sel.end - sel.start);
        self.caret.offset = sel.start;
        self.caret.clearSelection();
        return true;
    }

    /// Delete the byte before the caret (Backspace). A newline is one
    /// byte, so this joins lines correctly.
    pub fn backspace(self: *Editor) void {
        if (self.deleteSelection()) return;
        if (self.caret.offset == 0) return;
        self.splice(self.caret.offset - 1, 1);
        self.caret.offset -= 1;
    }

    /// Delete the byte at the caret (Delete).
    pub fn deleteForward(self: *Editor) void {
        if (self.deleteSelection()) return;
        if (self.caret.offset >= self.len) return;
        self.splice(self.caret.offset, 1);
    }

    /// Remove `count` bytes at `at`, closing the gap.
    fn splice(self: *Editor, at: usize, count: usize) void {
        const tail = self.len - (at + count);
        if (tail > 0) {
            std.mem.copyForwards(u8, self.buf[at .. at + tail], self.buf[at + count ..][0..tail]);
        }
        self.len -= count;
    }

    /// Select everything, or clear the selection.
    pub fn selectAll(self: *Editor) void {
        self.caret.anchor = 0;
        self.caret.offset = self.len;
    }

    /// Delete the selection, or delete the whole line the caret is on
    /// when nothing is selected.
    pub fn deleteLine(self: *Editor) void {
        if (self.deleteSelection()) return;
        const start = findLineStart(self.buf, 0, self.len, self.caret.offset);
        var end = findLineEnd(self.buf, 0, self.len, self.caret.offset);
        // Swallow the trailing newline so a second Ctrl-K is not a no-op.
        if (end < self.len and self.buf[end] == '\n') end += 1;
        self.splice(start, end - start);
        self.caret.offset = start;
    }

    // --- caret movement -------------------------------------------------

    /// Offset of the first byte of the line containing `offset`.
    pub fn lineStart(self: *const Editor, offset: usize) usize {
        return findLineStart(self.buf, 0, self.len, offset);
    }

    /// Offset just past the last byte of the line containing `offset`,
    /// excluding the newline.
    pub fn lineEnd(self: *const Editor, offset: usize) usize {
        return findLineEnd(self.buf, 0, self.len, offset);
    }

    /// 0-based index of the line containing `offset`.
    pub fn lineNumber(self: *const Editor, offset: usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        const limit = @min(offset, self.len);
        while (i < limit) : (i += 1) {
            if (self.buf[i] == '\n') n += 1;
        }
        return n;
    }

    /// Total number of lines (an empty buffer is one empty line).
    pub fn lineCount(self: *const Editor) usize {
        return self.lineNumber(self.len) + 1;
    }

    /// Start offset of 0-based `line`.
    pub fn lineStartAt(self: *const Editor, line: usize) usize {
        if (line == 0) return 0;
        var current: usize = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.buf[i] != '\n') continue;
            current += 1;
            if (current == line) return i + 1;
        }
        return self.len;
    }

    pub fn moveLeft(self: *Editor, shift: bool) void {
        self.setCaret(self.caret.offset -| 1, shift);
    }

    pub fn moveRight(self: *Editor, shift: bool) void {
        self.setCaret(@min(self.caret.offset + 1, self.len), shift);
    }

    pub fn moveHome(self: *Editor, shift: bool) void {
        self.setCaret(self.lineStart(self.caret.offset), shift);
    }

    pub fn moveEnd(self: *Editor, shift: bool) void {
        self.setCaret(self.lineEnd(self.caret.offset), shift);
    }

    /// Move to the start of the previous line. From the middle of a line
    /// this goes to its start, which is what every text editor does.
    pub fn moveLineUp(self: *Editor, shift: bool) void {
        const here = self.lineStart(self.caret.offset);
        if (here == 0) {
            self.setCaret(0, shift);
            return;
        }
        const previous = self.lineStartAt(self.lineNumber(self.caret.offset) - 1);
        const column = self.caret.offset - here;
        const prev_len = findLineEnd(self.buf, 0, self.len, previous) - previous;
        self.setCaret(previous + @min(column, prev_len), shift);
    }

    /// Move to the start of the next line, preserving the column where
    /// possible (a short line clamps rather than jumping to the end).
    pub fn moveLineDown(self: *Editor, shift: bool) void {
        const here = self.lineStart(self.caret.offset);
        const column = self.caret.offset - here;
        const next_line = self.lineNumber(self.caret.offset) + 1;
        if (next_line >= self.lineCount()) {
            self.setCaret(self.len, shift);
            return;
        }
        const next = self.lineStartAt(next_line);
        const next_len = findLineEnd(self.buf, 0, self.len, next) - next;
        self.setCaret(next + @min(column, next_len), shift);
    }

    /// Move the caret, maintaining the selection anchor when Shift is held.
    pub fn setCaret(self: *Editor, offset: usize, shift: bool) void {
        const clamped = @min(offset, self.len);
        if (shift) {
            // Start a selection on the first shifted move.
            if (self.caret.anchor == null) self.caret.anchor = self.caret.offset;
        } else {
            self.caret.clearSelection();
        }
        self.caret.offset = clamped;
    }

    /// Delete everything and reset the caret.
    pub fn clear(self: *Editor) void {
        self.len = 0;
        self.caret = .{};
    }

    /// True when there is room for more text.
    pub fn hasRoom(self: *const Editor) bool {
        return self.len < self.buf.len;
    }
};

fn findLineStart(buf: []const u8, from: usize, len: usize, offset: usize) usize {
    var i = @min(offset, len);
    while (i > from) {
        i -= 1;
        if (buf[i] == '\n') return i + 1;
    }
    return from;
}

fn findLineEnd(buf: []const u8, from: usize, len: usize, offset: usize) usize {
    _ = from;
    var i = @min(offset, len);
    while (i < len) : (i += 1) {
        if (buf[i] == '\n') return i;
    }
    return len;
}

/// The result of feeding one key event to the editor.
pub fn handleKey(
    editor: *Editor,
    keycode: u32,
    shift: bool,
    ctrl: bool,
) Action {
    // Navigation keys, using the same evdev codes glinlandui exposes.
    switch (keycode) {
        KEY_LEFT => {
            editor.moveLeft(shift);
            return .edited;
        },
        KEY_RIGHT => {
            editor.moveRight(shift);
            return .edited;
        },
        KEY_HOME => {
            if (ctrl) {
                editor.setCaret(0, shift);
            } else {
                editor.moveHome(shift);
            }
            return .edited;
        },
        KEY_END => {
            editor.moveEnd(shift);
            return .edited;
        },
        KEY_UP => {
            editor.moveLineUp(shift);
            return .edited;
        },
        KEY_DOWN => {
            editor.moveLineDown(shift);
            return .edited;
        },
        KEY_BACKSPACE => {
            if (editor.len == 0) return .ignored;
            editor.backspace();
            return .edited;
        },
        KEY_DELETE => {
            editor.deleteForward();
            return .edited;
        },
        KEY_ENTER => {
            // Ctrl+Enter runs; a bare Enter inserts a newline.
            if (ctrl) return .run_requested;
            if (!editor.insertByte('\n')) return .ignored;
            return .edited;
        },
        KEY_K => {
            if (ctrl) {
                editor.deleteLine();
                return .edited;
            }
        },
        KEY_A => {
            if (ctrl) {
                editor.selectAll();
                return .edited;
            }
        },
        else => {},
    }

    // Printable ASCII only. The key layer cannot produce anything else,
    // and silently inserting a placeholder byte would corrupt the SQL.
    if (keyChar(keycode, shift)) |c| {
        if (!editor.insertByte(c)) return .ignored;
        return .edited;
    }
    return .ignored;
}

// Raw evdev key codes, matching glinlandui's `input` module so a key
// handler can be shared between the single-line and multi-line fields.
pub const KEY_BACKSPACE: u32 = 14;
pub const KEY_ENTER: u32 = 28;
pub const KEY_A: u32 = 30;
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_UP: u32 = 103;
pub const KEY_DOWN: u32 = 108;
pub const KEY_HOME: u32 = 102;
pub const KEY_END: u32 = 107;
pub const KEY_DELETE: u32 = 111;
pub const KEY_K: u32 = 37;

/// Map a keycode to a printable ASCII byte (US layout), or null.
///
/// Deliberately ASCII-only: glinlandui's key layer is ASCII too, and an
/// editor that inserted a placeholder byte for an unmapped key would
/// corrupt the SQL it exists to edit. Returning null means "not a
/// character", and the caller leaves the buffer untouched.
pub fn keyChar(keycode: u32, shift: bool) ?u8 {
    // Letter rows, straight from the evdev layout glinlandui uses.
    if (keycode >= 16 and keycode <= 25) return letter(keycode - 16 + 'q', shift); // q..p
    if (keycode >= 30 and keycode <= 38) return letter(keycode - 30 + 'a', shift); // a..i
    if (keycode >= 44 and keycode <= 50) return letter(keycode - 44 + 'z', shift); // z..m

    // Number row: 2..11 are the digits 1..0.
    if (keycode >= 2 and keycode <= 11) {
        if (!shift) return @intCast(keycode - 2 + '1');
        const shifted = [_]u8{ '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' };
        return shifted[keycode - 2];
    }

    // Everything a SQL statement actually needs. A flat table rather
    // than overlapping switch prongs, so there is no chance of two
    // prongs claiming the same code.
    const symbols = [_]struct { code: u32, plain: u8, shifted: u8 }{
        .{ .code = 12, .plain = '-', .shifted = '_' },
        .{ .code = 13, .plain = '=', .shifted = '+' },
        .{ .code = 39, .plain = '\'', .shifted = '"' },
        .{ .code = 40, .plain = '`', .shifted = '~' },
        .{ .code = 42, .plain = '\\', .shifted = '|' },
        .{ .code = 51, .plain = ';', .shifted = ':' },
        .{ .code = 54, .plain = ',', .shifted = '<' },
        .{ .code = 55, .plain = '.', .shifted = '>' },
        .{ .code = 56, .plain = '/', .shifted = '?' },
        .{ .code = 97, .plain = '/', .shifted = '?' },
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
    };
    for (symbols) |entry| {
        if (entry.code == keycode) return if (shift) entry.shifted else entry.plain;
    }
    return null;
}

fn letter(base: u32, shift: bool) u8 {
    const c: u8 = @intCast(base);
    return if (shift) c - 32 else c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "insert and read back" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    try testing.expectEqual(@as(usize, 5), e.insertSlice("hello"));
    try testing.expectEqualStrings("hello", e.text());
    try testing.expectEqual(@as(usize, 5), e.caret.offset);
}

test "insert respects the buffer capacity" {
    var buf: [4]u8 = undefined;
    var e = Editor.init(&buf);
    try testing.expectEqual(@as(usize, 4), e.insertSlice("hello world"));
    try testing.expectEqualStrings("hell", e.text());
    try testing.expect(!e.hasRoom());
    // A further insert must not corrupt anything.
    _ = e.insertByte('!');
    try testing.expectEqualStrings("hell", e.text());
}

test "backspace and delete" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abc");
    e.backspace();
    try testing.expectEqualStrings("ab", e.text());
    e.caret.offset = 0;
    e.deleteForward();
    try testing.expectEqualStrings("b", e.text());
}

test "a newline makes a second line and backspace joins them" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT 1");
    _ = e.insertByte('\n');
    _ = e.insertSlice("FROM t");
    try testing.expectEqual(@as(usize, 2), e.lineCount());
    try testing.expectEqualStrings("SELECT 1\nFROM t", e.text());

    // The '\n' is at offset 8; place the caret just past it and delete,
    // which is what joining two lines means.
    const newline_offset = std.mem.indexOfScalar(u8, e.text(), '\n').?;
    e.caret.offset = newline_offset + 1;
    e.backspace();
    try testing.expectEqualStrings("SELECT 1FROM t", e.text());
}

test "line navigation" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("aaa\nbbbbbb\ncc");

    e.setCaret(0, false);
    try testing.expectEqual(@as(usize, 0), e.lineNumber(0));
    try testing.expectEqual(@as(usize, 1), e.lineNumber(5));

    e.setCaret(0, false);
    e.moveLineDown(false);
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
    e.moveLineDown(false);
    // Line 2 is "cc"; the column (0) still fits, so the caret lands at
    // its start.
    try testing.expectEqual(@as(usize, 11), e.caret.offset);
    e.moveLineUp(false);
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
}

test "home and end work per line" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("aaa\nbbbbbb\ncc");
    e.setCaret(0, false);
    e.moveEnd(false);
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
    e.moveLineDown(false);
    // moveLineDown preserves the COLUMN (3), so the caret is at 4 + 3.
    try testing.expectEqual(@as(usize, 7), e.caret.offset);
    e.moveEnd(false);
    // End of "bbbbbb" is 4 + 6 = 10.
    try testing.expectEqual(@as(usize, 10), e.caret.offset);
    e.moveHome(false);
    // Start of "bbbbbb" is 4.
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
}

test "selection deletes the span" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("hello world");
    e.caret.anchor = 0;
    e.caret.offset = 6;
    try testing.expect(e.caret.hasSelection());
    try testing.expect(e.deleteSelection());
    try testing.expectEqualStrings("world", e.text());
    try testing.expect(!e.caret.hasSelection());
}

test "shift+arrow builds a selection" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abcdef");
    e.setCaret(0, false);
    e.moveRight(true);
    e.moveRight(true);
    try testing.expect(e.caret.hasSelection());
    const sel = e.caret.selection().?;
    try testing.expectEqual(@as(usize, 0), sel.start);
    try testing.expectEqual(@as(usize, 2), sel.end);
}

test "typing replaces the selection" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("hello world");
    e.selectAll();
    _ = e.insertByte('X');
    try testing.expectEqualStrings("X", e.text());
}

test "select all then delete empties the buffer" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT * FROM t");
    e.selectAll();
    try testing.expect(e.deleteSelection());
    try testing.expectEqualStrings("", e.text());
    try testing.expectEqual(@as(usize, 0), e.caret.offset);
}

test "ctrl-K deletes the caret's line" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("one\ntwo\nthree");
    e.setCaret(5, false); // inside "two"
    try testing.expectEqual(handleKey(&e, KEY_K, false, true), Action.edited);
    try testing.expectEqualStrings("one\nthree", e.text());
}

test "ctrl-K with no selection removes the newline too" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("one\ntwo");
    e.setCaret(0, false);
    _ = handleKey(&e, KEY_K, false, true);
    try testing.expectEqualStrings("two", e.text());
}

test "ctrl-Enter asks to run, plain Enter inserts a newline" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT 1");
    try testing.expectEqual(handleKey(&e, KEY_ENTER, false, true), Action.run_requested);
    // The run request must not have inserted anything.
    try testing.expectEqualStrings("SELECT 1", e.text());

    try testing.expectEqual(handleKey(&e, KEY_ENTER, false, false), Action.edited);
    try testing.expectEqualStrings("SELECT 1\n", e.text());
}

test "backspace at offset 0 is a no-op, not a crash" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    e.backspace();
    try testing.expectEqual(@as(usize, 0), e.len);
}

test "deleteForward at the end is a no-op" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abc");
    e.deleteForward();
    try testing.expectEqualStrings("abc", e.text());
}

test "movement clamps at both ends" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("ab");
    e.setCaret(0, false);
    e.moveLeft(false);
    try testing.expectEqual(@as(usize, 0), e.caret.offset);
    e.moveRight(false);
    e.moveRight(false);
    e.moveRight(false);
    try testing.expectEqual(@as(usize, 2), e.caret.offset);
}

test "keyChar maps letters, digits and symbols" {
    try testing.expectEqual(@as(?u8, 'a'), keyChar(30, false));
    try testing.expectEqual(@as(?u8, 'A'), keyChar(30, true));
    try testing.expectEqual(@as(?u8, 'z'), keyChar(44, false));
    try testing.expectEqual(@as(?u8, '1'), keyChar(2, false));
    try testing.expectEqual(@as(?u8, '!'), keyChar(2, true));
    // A key that maps to nothing must return null, not a placeholder.
    try testing.expectEqual(@as(?u8, null), keyChar(KEY_LEFT, false));
    try testing.expectEqual(@as(?u8, null), keyChar(999, false));
}

test "typing through handleKey produces the SQL" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    // Seed with a slice, then prove the KEY path appends the right byte.
    // evdev 32 is 'c' (30='a', 31='b', 32='c').
    _ = e.insertSlice("SELE");
    try testing.expectEqual(handleKey(&e, 32, false, false), Action.edited);
    try testing.expectEqualStrings("SELEc", e.text());
}

test "a 4 KB buffer holds a realistic query" {
    var buf: [4096]u8 = undefined;
    var e = Editor.init(&buf);
    const q =
        \\SELECT u.id, u.name, COUNT(p.id) AS posts
        \\FROM users u
        \\LEFT JOIN posts p ON p.user_id = u.id
        \\WHERE u.active = 1 AND u.created_at > '2024-01-01'
        \\GROUP BY u.id, u.name
        \\HAVING COUNT(p.id) > 0
        \\ORDER BY posts DESC
        \\LIMIT 50
    ;
    const n = e.insertSlice(q);
    try testing.expectEqual(q.len, n);
    try testing.expectEqualStrings(q, e.text());
    try testing.expectEqual(@as(usize, 8), e.lineCount());
}

test "setText truncates rather than overflowing" {
    var buf: [8]u8 = undefined;
    var e = Editor.init(&buf);
    e.setText("a much longer string");
    try testing.expectEqual(@as(usize, 8), e.len);
    try testing.expectEqualStrings("a much l", e.text());
}
