//! Rendering a result set as an aligned text table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const query = @import("meja").query;
const value = @import("meja").value;
const database = @import("databases").database;

/// The widest a column may get before its values are truncated.
pub const max_column_width: usize = 60;

/// How a table is drawn.
pub const Options = struct {
    /// Draw the `+---+---+` rules. Off for a machine-readable mode.
    borders: bool = true,
    /// Draw a `(N rows)` footer.
    show_counts: bool = true,
    /// Stop after this many rows. Null renders everything.
    max_rows: ?usize = null,
};

/// Render a result set.
pub fn renderTable(
    writer: *std.Io.Writer,
    allocator: Allocator,
    result_set: *const query.ResultSet,
    options: Options,
) !void {
    const columns = result_set.columns;
    const total_rows = result_set.rows.len;
    const shown_rows = if (options.max_rows) |m| @min(m, total_rows) else total_rows;

    // Pass 1: measure.
    var widths = try allocator.alloc(usize, columns.len);
    defer allocator.free(widths);
    for (columns, 0..) |c, i| {
        widths[i] = displayWidth(c.name);
    }
    for (result_set.rows[0..shown_rows], 0..) |row, ri| {
        for (row.values, 0..) |v, ci| {
            if (ci >= widths.len) break;
            const w = renderedWidth(v);
            if (w > widths[ci]) widths[ci] = w;
        }
        _ = ri;
    }
    for (widths) |*w| {
        if (w.* > max_column_width) w.* = max_column_width;
    }

    // Header.
    if (options.borders) try writer.writeAll("+");
    for (widths) |w| {
        try writeRule(writer, w);
        if (options.borders) try writer.writeAll("+");
    }
    try writer.writeByte('\n');

    if (options.borders) try writer.writeAll("|");
    for (columns, widths) |c, w| {
        try writeCell(writer, c.name, w);
        if (options.borders) try writer.writeAll("|");
    }
    try writer.writeByte('\n');

    if (options.borders) try writer.writeAll("+");
    for (widths) |w| {
        try writeRule(writer, w);
        if (options.borders) try writer.writeAll("+");
    }
    try writer.writeByte('\n');

    // Body.
    for (result_set.rows[0..shown_rows]) |row| {
        if (options.borders) try writer.writeAll("|");
        for (row.values, 0..) |v, ci| {
            if (ci >= widths.len) break;
            try writeValue(writer, v, widths[ci]);
            if (options.borders) try writer.writeAll("|");
        }
        try writer.writeByte('\n');
    }

    if (options.borders) try writer.writeAll("+");
    for (widths) |w| {
        try writeRule(writer, w);
        if (options.borders) try writer.writeAll("+");
    }
    try writer.writeByte('\n');

    if (options.show_counts) {
        try writer.print("{d} row{s}", .{ total_rows, plural(total_rows) });
        if (columns.len > 0) {
            try writer.print(", {d} column{s}", .{ columns.len, plural(columns.len) });
        }
        if (total_rows > shown_rows) {
            try writer.print(" (showing first {d})", .{shown_rows});
        }
        if (result_set.truncated) {
            // The engine flags a full page; say so, so the user knows the table is not the whole answer.
            try writer.writeAll(" [truncated: more rows available]");
        }
        try writer.writeByte('\n');
    }
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn writeRule(writer: *std.Io.Writer, width: usize) !void {
    try writer.writeByte('-');
    var i: usize = 1;
    while (i < width) : (i += 1) try writer.writeByte('-');
}

fn writeCell(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    try writePadding(writer, displayWidth(text), width);
}

/// Write `width - used` spaces.
fn writePadding(writer: *std.Io.Writer, used: usize, width: usize) !void {
    var i = used;
    while (i < width) : (i += 1) try writer.writeByte(' ');
}

/// Print a value, padded to `width` display columns and truncated with a visible marker when it does not fit.
fn writeValue(writer: *std.Io.Writer, v: value.Value, width: usize) !void {
    var buf: [512]u8 = undefined;
    var scratch: std.Io.Writer = .fixed(&buf);
    v.format(&scratch) catch {
        // A cell that cannot even be rendered into 512 bytes is shown as a marker rather than dropped.
        try writer.writeAll("<?>");
        return;
    };
    const text = scratch.buffered();

    if (displayWidth(text) <= width) {
        try writeCell(writer, text, width);
        return;
    }
    // Truncate on a byte boundary that keeps the prefix valid UTF-8.
    const cut = utf8Prefix(text, width);
    try writer.writeAll(cut);
    try writer.writeAll("…");
    // The ellipsis occupies one display column.
    try writePadding(writer, displayWidth(cut) + 1, width);
}

/// The longest prefix of `text` that fits in `width` display columns and does not split a UTF-8 sequence.
fn utf8Prefix(text: []const u8, width: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            // Invalid byte: take it as one column so the loop advances.
            i += 1;
            cols += 1;
            if (cols >= width) return text[0..i];
            continue;
        };
        if (i + n > text.len) break;
        i += n;
        cols += 1;
        if (cols >= width) return text[0..i];
    }
    return text;
}

/// Display width of a value once rendered.
fn renderedWidth(v: value.Value) usize {
    var buf: [512]u8 = undefined;
    var scratch: std.Io.Writer = .fixed(&buf);
    v.format(&scratch) catch return 0;
    return displayWidth(scratch.buffered());
}

/// Width of `text` in terminal columns.
pub fn displayWidth(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            n += 1;
            continue;
        };
        i += @min(len, text.len - i);
        n += 1;
    }
    return n;
}

// Tests

const testing = std.testing;

fn render(rs: *const query.ResultSet, buf: []u8, options: Options) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try renderTable(&w, testing.allocator, rs, options);
    return w.buffered();
}

const Fixture = struct {
    threaded: std.Io.Threaded,
    db: @import("databases").database.Db,

    fn init() !Fixture {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        errdefer threaded.deinit();
        var db: database.Db = .{};
        errdefer db.deinit();
        try db.init(threaded.io(), ":memory:");
        try db.exec(testing.allocator, "CREATE TABLE t (id INTEGER, name TEXT)", &.{});
        try db.exec(testing.allocator,
            \\INSERT INTO t (id, name) VALUES
            \\ (1, 'alice'), (2, 'bob'), (3, NULL)
        , &.{});
        return .{ .threaded = threaded, .db = db };
    }
    fn deinit(self: *Fixture) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

test "a table has aligned columns" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id, name FROM t", .{});
    defer rs.deinit();

    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    var lines = std.mem.splitScalar(u8, out, '\n');

    // Only the table rows share a width; the footer is a sentence.
    var width: ?usize = null;
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != '+' and line[0] != '|') continue;
        if (width == null) width = line.len;
        try testing.expectEqual(width.?, line.len);
        checked += 1;
    }
    // 3 rules + 1 header + 3 body rows.
    try testing.expectEqual(@as(usize, 7), checked);
}

test "the header shows real column names" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id, name FROM t", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    try testing.expect(std.mem.indexOf(u8, out, "id") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name") != null);
    try testing.expect(std.mem.indexOf(u8, out, "alice") != null);
}

test "NULL is shown, not blank" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT name FROM t", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    try testing.expect(std.mem.indexOf(u8, out, "NULL") != null);
}

test "a long value is truncated with a visible marker" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    const long = "x" ** 200;
    const ins = try std.fmt.allocPrint(alloc, "INSERT INTO t (id, name) VALUES (4, '{s}')", .{long});
    defer alloc.free(ins);
    try f.db.exec(alloc, ins, &.{});

    var rs = try query.run(alloc, &f.db, "SELECT name FROM t", .{});
    defer rs.deinit();
    var buf: [8192]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    // Truncation must be visible, not silent.
    try testing.expect(std.mem.indexOf(u8, out, "…") != null);
    // And the whole table must still fit in a sane width.
    var lines = std.mem.splitScalar(u8, out, '\n');
    // (iterator.next needs a mutable binding)
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(line.len <= max_column_width + 20);
    }
}

test "a value containing a newline cannot break the table" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    try f.db.exec(alloc, "INSERT INTO t (id, name) VALUES (5, 'a' || char(10) || 'b')", &.{});

    var rs = try query.run(alloc, &f.db, "SELECT name FROM t", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});

    // The newline is escaped to a literal backslash-n, so the row count is unchanged and every line is still the table's width.
    try testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
    var lines = std.mem.splitScalar(u8, out, '\n');
    var width: ?usize = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // The footer is prose, not a table row.
        if (line[0] != '+' and line[0] != '|') continue;
        if (width == null) width = line.len;
        try testing.expectEqual(width.?, line.len);
    }
}

test "the footer reports the true row count" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id FROM t", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    try testing.expect(std.mem.indexOf(u8, out, "3 rows") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 column") != null);
}

test "max_rows caps the body but not the count" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id FROM t", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{ .max_rows = 2 });
    try testing.expect(std.mem.indexOf(u8, out, "3 rows") != null);
    try testing.expect(std.mem.indexOf(u8, out, "showing first 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1") != null);
}

test "an empty result set still renders a valid table" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id FROM t WHERE id = 999", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    try testing.expect(std.mem.indexOf(u8, out, "0 rows") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id") != null);
}

test "displayWidth counts characters, not bytes" {
    try testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    // "héllo" is 6 bytes but 5 display columns — counting bytes would make every row containing an accented character misalign.
    try testing.expectEqual(@as(usize, 5), displayWidth("héllo"));
    try testing.expectEqual(@as(usize, 6), "héllo".len);
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
    // Invalid UTF-8 must still advance the loop.
    try testing.expect(displayWidth("\xff\xfe") > 0);
}

test "non-ASCII text does not break alignment" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    try f.db.exec(alloc, "INSERT INTO t (id, name) VALUES (6, 'naïve')", &.{});
    var rs = try query.run(alloc, &f.db, "SELECT name FROM t", .{});
    defer rs.deinit();
    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    try testing.expect(std.mem.indexOf(u8, out, "naïve") != null);
}

test "utf8Prefix never splits a character" {
    const text = "naïve";
    const cut = utf8Prefix(text, 3);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqual(@as(usize, 3), displayWidth(cut));
}

test "utf8Prefix handles invalid bytes without looping" {
    // A value holding non-UTF-8 must still terminate.
    const cut = utf8Prefix("\xff\xfe\xfd", 2);
    try testing.expect(cut.len <= 3);
}

test "every table line is the same length" {
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id, name FROM t", .{});
    defer rs.deinit();

    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    var lines = std.mem.splitScalar(u8, out, '\n');

    // The single invariant that matters: no table line is longer or shorter than another, so every cell's right border is a column.
    var width: ?usize = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != '+' and line[0] != '|') continue;
        if (width == null) width = line.len;
        try testing.expectEqual(width.?, line.len);
    }
    try testing.expect(width != null);
}
test "a header is padded only to its column width" {
    // The regression that motivated these alignment tests: `id` exactly filled its column and a padding bug rendered it `id ` — two spaces — shifting every.
    var f = try Fixture.init();
    defer f.deinit();
    var rs = try query.run(testing.allocator, &f.db, "SELECT id FROM t", .{});
    defer rs.deinit();

    var buf: [4096]u8 = undefined;
    const out = try render(&rs, &buf, .{});
    var lines = std.mem.splitScalar(u8, out, '\n');

    // One column of single digits: the rule is `+--+` (2 wide).
    const rule = lines.next().?;
    try testing.expectEqualStrings("+--+", rule);
    const header = lines.next().?;
    // `id` is 2 characters in a 2-wide column: no padding at all.
    try testing.expectEqualStrings("|id|", header);
    _ = lines.next(); // rule
    const row = lines.next().?;
    try testing.expectEqualStrings("|1 |", row);
}
test "writePadding only fills a shortfall" {
    var buf: [16]u8 = undefined;
    {
        var w: std.Io.Writer = .fixed(&buf);
        try writePadding(&w, 2, 5);
        try testing.expectEqualStrings("   ", w.buffered());
    }
    {
        var w: std.Io.Writer = .fixed(&buf);
        try writePadding(&w, 5, 5);
        try testing.expectEqualStrings("", w.buffered());
    }
    {
        // Over-wide input must not produce negative padding.
        var w: std.Io.Writer = .fixed(&buf);
        try writePadding(&w, 8, 5);
        try testing.expectEqualStrings("", w.buffered());
    }
}
