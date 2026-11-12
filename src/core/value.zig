//! Typed values, recovered from the all-text rows the `databases` binding returns.

const std = @import("std");

/// Storage class of a value, mirroring SQLite's `typeof()` vocabulary.
pub const StorageClass = enum {
    /// SQL NULL. Distinct from the empty string.
    null_value,
    /// A 64-bit signed integer.
    integer,
    /// An IEEE-754 double.
    real,
    /// UTF-8 / arbitrary bytes stored as text.
    text,
    /// Raw bytes. The value may not be valid UTF-8.
    blob,
    /// A type name this build does not know about (a newer SQLite, or a non-SQLite backend).
    unknown,

    /// Parse a `typeof()` result.
    pub fn parse(text: []const u8) StorageClass {
        if (std.mem.eql(u8, text, "null")) return .null_value;
        if (std.mem.eql(u8, text, "integer")) return .integer;
        if (std.mem.eql(u8, text, "real")) return .real;
        if (std.mem.eql(u8, text, "text")) return .text;
        if (std.mem.eql(u8, text, "blob")) return .blob;
        return .unknown;
    }
};

/// A single cell value with its type attached.
pub const Value = union(StorageClass) {
    null_value: void,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
    unknown: []const u8,

    /// Decode a value from the pair of columns the query engine produces: the `typeof()` string and the raw text.
    pub fn fromStorageClass(storage: []const u8, text: []const u8) Value {
        return switch (StorageClass.parse(storage)) {
            .null_value => .null_value,
            .integer => Value{ .integer = std.fmt.parseInt(i64, text, 10) catch return Value{ .text = text } },
            .real => Value{ .real = std.fmt.parseFloat(f64, text) catch return Value{ .text = text } },
            .text => .{ .text = text },
            .blob => .{ .blob = text },
            .unknown => .{ .unknown = text },
        };
    }

    /// Decode a value when no type information is available.
    pub fn fromUntypedText(text: []const u8) Value {
        return .{ .text = text };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_value;
    }

    /// The value as borrowed text, for the text/blob/unknown classes only.
    pub fn asTextSlice(self: Value) ?[]const u8 {
        return switch (self) {
            .text, .blob, .unknown => |t| t,
            else => null,
        };
    }

    /// True when this value is one of the classes that owns text.
    pub fn hasText(self: Value) bool {
        return self.asTextSlice() != null;
    }

    /// Write the value's textual form — the same bytes `format` would produce, but without display-only decoration (no `NULL` label, no `<blob N bytes>`, no.
    pub fn writeAsText(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .null_value => {},
            .integer => |i| try writer.print("{d}", .{i}),
            .real => |f| try writer.print("{d}", .{f}),
            .text, .blob, .unknown => |t| try writer.writeAll(t),
        }
    }

    /// The value parsed as an integer, or null if it is not numeric.
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .real => |f| @intFromFloat(f),
            .text, .unknown => |t| std.fmt.parseInt(i64, t, 10) catch null,
            else => null,
        };
    }

    /// The value parsed as a float, or null if it is not numeric.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .real => |f| f,
            .text, .unknown => |t| std.fmt.parseFloat(f64, t) catch null,
            else => null,
        };
    }

    /// Write a short human-readable rendering.
    pub fn format(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .null_value => try writer.writeAll("NULL"),
            .integer => |i| try writer.print("{d}", .{i}),
            .real => |f| try writer.print("{d}", .{f}),
            .text => |t| try writeEscaped(t, writer),
            .unknown => |t| try writer.print("~{s}", .{t}),
            .blob => |b| try writer.print("<blob {d} bytes>", .{b.len}),
        }
    }

    /// Length in bytes this value occupies when rendered by `format`.
    pub fn formatWidth(self: Value) usize {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        self.format(&w) catch return 0;
        return w.end;
    }
};

/// Write text with control characters escaped, so a value containing a newline or a tab cannot break table layout or inject terminal escapes.
pub fn writeEscaped(text: []const u8, writer: *std.Io.Writer) !void {
    for (text) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x1b => try writer.writeAll("\\e"),
            0x07 => try writer.writeAll("\\a"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x06, 0x0b, 0x0e...0x1a, 0x1c...0x1f => {
                try writer.print("\\x{x:0>2}", .{c});
            },
            else => try writer.writeByte(c),
        }
    }
}

/// True when the value contains bytes that are not valid UTF-8, which means it cannot be rendered as text even in principle.
pub fn isValidUtf8(value: Value) bool {
    return switch (value) {
        .text, .unknown => |t| std.unicode.utf8ValidateSlice(t),
        else => true,
    };
}

// Tests

const testing = std.testing;

fn renderTo(value: Value, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try value.format(&w);
    return w.buffered();
}

fn renderText(value: Value, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try value.writeAsText(&w);
    return w.buffered();
}

test "StorageClass.parse maps the typeof() vocabulary" {
    try testing.expectEqual(StorageClass.null_value, StorageClass.parse("null"));
    try testing.expectEqual(StorageClass.integer, StorageClass.parse("integer"));
    try testing.expectEqual(StorageClass.real, StorageClass.parse("real"));
    try testing.expectEqual(StorageClass.text, StorageClass.parse("text"));
    try testing.expectEqual(StorageClass.blob, StorageClass.parse("blob"));
    try testing.expectEqual(StorageClass.unknown, StorageClass.parse("geometry"));
    try testing.expectEqual(StorageClass.unknown, StorageClass.parse(""));
}

test "NULL and the empty string are distinguishable once typeof() is known" {
    // This is the entire reason the query engine pairs values with their storage class.
    const from_null = Value.fromStorageClass("null", "");
    const from_empty = Value.fromStorageClass("text", "");
    var nbuf: [32]u8 = undefined;
    var tbuf: [32]u8 = undefined;

    try testing.expect(from_null.isNull());
    try testing.expect(!from_empty.isNull());
    // Display form: NULL is labelled, the empty string is blank.
    try testing.expectEqualStrings("NULL", try renderTo(from_null, &nbuf));
    try testing.expectEqualStrings("", try renderTo(from_empty, &nbuf));
    // SQL-literal form: NULL contributes nothing, so a generated `WHERE col = ''` can never be confused with `WHERE col IS NULL`.
    try testing.expectEqualStrings("", try renderText(from_null, &tbuf));
    try testing.expectEqualStrings("", try renderText(from_empty, &tbuf));

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("NULL", try renderTo(from_null, &buf));
    try testing.expectEqualStrings("", try renderTo(from_empty, &buf));
}

test "the integer/text ambiguity is resolved by typeof()" {
    const as_int = Value.fromStorageClass("integer", "42");
    const as_text = Value.fromStorageClass("text", "42");
    var ibuf: [32]u8 = undefined;

    try testing.expectEqual(@as(i64, 42), as_int.asInt().?);
    try testing.expectEqualStrings("42", try renderTo(as_text, &ibuf));
    // Same bytes, different type — the point of the whole module.
    try testing.expectEqualStrings("42", try renderTo(as_int, &ibuf));
    try testing.expectEqualStrings("42", try renderTo(as_text, &ibuf));
    try testing.expect(std.meta.activeTag(as_int) != std.meta.activeTag(as_text));
}

test "fromStorageClass decodes each class" {
    try testing.expect(Value.fromStorageClass("integer", "-9223372036854775808") == .integer);
    try testing.expectEqual(@as(i64, -9223372036854775808), Value.fromStorageClass("integer", "-9223372036854775808").asInt().?);
    try testing.expectEqual(@as(f64, 1.5), Value.fromStorageClass("real", "1.5").asFloat().?);
    try testing.expectEqualStrings("hi", Value.fromStorageClass("text", "hi").asTextSlice().?);
    try testing.expectEqual(@as(usize, 3), Value.fromStorageClass("blob", "abc").blob.len);
}

test "a malformed numeric payload degrades to text instead of vanishing" {
    // typeof() said integer but the bytes are not a number.
    const v = Value.fromStorageClass("integer", "not-a-number");
    var mbuf: [32]u8 = undefined;
    try testing.expectEqualStrings("not-a-number", try renderTo(v, &mbuf));
}

test "fromUntypedText cannot claim NULL" {
    // Honest about its ignorance: an empty untyped value might be NULL or '', and this layer has no way to know which.
    try testing.expect(!Value.fromUntypedText("").isNull());
    try testing.expectEqualStrings("", Value.fromUntypedText("").asTextSlice().?);
}

test "format renders each class" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("NULL", try renderTo(.null_value, &buf));
    try testing.expectEqualStrings("42", try renderTo(.{ .integer = 42 }, &buf));
    try testing.expectEqualStrings("-7", try renderTo(.{ .integer = -7 }, &buf));
    try testing.expectEqualStrings("hello", try renderTo(.{ .text = "hello" }, &buf));
    try testing.expectEqualStrings("<blob 4 bytes>", try renderTo(.{ .blob = "abcd" }, &buf));
    try testing.expectEqualStrings("~weird", try renderTo(.{ .unknown = "weird" }, &buf));
}

test "a real renders with a decimal point, unlike an integer" {
    var buf: [64]u8 = undefined;
    // The point of the distinction: 1 (INTEGER) and 1.5 (REAL) must not render identically, or a grid hides the column's storage class.
    try testing.expectEqualStrings("1", try renderTo(.{ .integer = 1 }, &buf));
    try testing.expectEqualStrings("1.5", try renderTo(.{ .real = 1.5 }, &buf));
    // A whole-valued REAL still prints as a float literal.
    try testing.expectEqualStrings("1", try renderText(.{ .real = 1.0 }, &buf));
}

test "control characters are escaped so a value cannot break the layout" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("a\\nb", try renderTo(.{ .text = "a\nb" }, &buf));
    try testing.expectEqualStrings("a\\tb", try renderTo(.{ .text = "a\tb" }, &buf));
    try testing.expectEqualStrings("a\\\\b", try renderTo(.{ .text = "a\\b" }, &buf));
    try testing.expectEqualStrings("\\e[31m", try renderTo(.{ .text = "\x1b[31m" }, &buf));
    try testing.expectEqualStrings("\\x00", try renderTo(.{ .text = "\x00" }, &buf));
}

test "asInt coerces a real, and refuses text" {
    try testing.expectEqual(@as(i64, 3), (Value{ .real = 3.7 }).asInt().?);
    try testing.expectEqual(@as(?i64, null), (Value{ .text = "abc" }).asInt());
    const nv: Value = .null_value;
    try testing.expectEqual(@as(?i64, null), nv.asInt());
}

test "asFloat promotes an integer" {
    try testing.expectEqual(@as(f64, 5.0), (Value{ .integer = 5 }).asFloat().?);
    const nv2: Value = .null_value;
    try testing.expectEqual(@as(?f64, null), nv2.asFloat());
}

test "formatWidth agrees with format" {
    var buf: [64]u8 = undefined;
    for ([_]Value{
        .null_value,
        .{ .integer = 12345 },
        .{ .text = "hello" },
        .{ .blob = "xy" },
    }) |v| {
        try testing.expectEqual((try renderTo(v, &buf)).len, v.formatWidth());
    }
}

test "isValidUtf8 catches binary masquerading as text" {
    try testing.expect(isValidUtf8(.{ .text = "héllo" }));
    try testing.expect(!isValidUtf8(.{ .text = "\xff\xfe" }));
    // Blobs are expected to be binary, so they are not flagged.
    try testing.expect(isValidUtf8(.{ .blob = "\xff\xfe" }));
}

/// Render a value into `buf` for display in a grid or table cell.
pub fn render(buf: []u8, v: Value) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return buf[0..0];
    return w.buffered();
}

test "render shows numbers, which asTextSlice cannot" {
    var buf: [64]u8 = undefined;
    // This is the whole reason render exists.
    try testing.expectEqualStrings("42", render(&buf, .{ .integer = 42 }));
    try testing.expectEqualStrings("-7", render(&buf, .{ .integer = -7 }));
    try testing.expectEqualStrings("1.5", render(&buf, .{ .real = 1.5 }));

    // The accessor that hides them.
    try testing.expectEqual(@as(?[]const u8, null), (Value{ .integer = 42 }).asTextSlice());
    try testing.expectEqual(@as(?[]const u8, null), (Value{ .real = 1.5 }).asTextSlice());
}

test "render handles every class" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("NULL", render(&buf, .null_value));
    try testing.expectEqualStrings("alice", render(&buf, .{ .text = "alice" }));
    try testing.expectEqualStrings("<blob 3 bytes>", render(&buf, .{ .blob = "abc" }));
    try testing.expectEqualStrings("~odd", render(&buf, .{ .unknown = "odd" }));
}

test "render escapes control characters and truncates" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a\\nb", render(&buf, .{ .text = "a\nb" }));

    // A value too long for the buffer is cut, not overflowed.
    var small: [4]u8 = undefined;
    const out = render(&small, .{ .text = "abcdefghij" });
    try testing.expect(out.len <= small.len);
}

test "render never writes past the buffer" {
    var tiny: [1]u8 = undefined;
    _ = render(&tiny, .{ .integer = 12345 });
    var two: [2]u8 = undefined;
    _ = render(&two, .{ .text = "hello" });
}
