//! Recovering column names from SQL text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlmod = @import("sql.zig");

/// One entry in a SELECT list.
pub const Item = struct {
    /// The expression as written, e.g.
    expr: []const u8,
    /// The best name we can infer for this column.
    name: []const u8,
    /// True when this entry is `*` or `qualifier.*` and must be expanded against the schema to get real names.
    is_star: bool = false,
    /// For `t.*`, the qualifier; null for a bare `*`.
    star_qualifier: ?[]const u8 = null,
};

/// A parsed SELECT list.
pub const SelectList = struct {
    items: []const Item,
    /// Byte range of the select list within the original statement.
    offset: usize,
    len: usize,
    /// The statement *after* the select list, starting at the `FROM`/`WHERE`/etc.
    rest: []const u8,

    pub fn deinit(self: SelectList, allocator: Allocator) void {
        allocator.free(self.items);
    }

    /// Does this list need schema information to resolve its names?
    pub fn needsExpansion(self: SelectList) bool {
        for (self.items) |it| {
            if (it.is_star) return true;
        }
        return false;
    }

    /// Index of the first `*` entry, or null if there is none.
    pub fn firstStar(self: SelectList) ?usize {
        for (self.items, 0..) |it, i| {
            if (it.is_star) return i;
        }
        return null;
    }
};

pub const ParseError = error{
    /// No SELECT keyword could be located.
    NoSelect,
    /// The select list is empty (e.g. `SELECT FROM t`).
    EmptyList,
};

/// Locate the select list of a statement and split it into items.
pub fn parse(allocator: Allocator, statement: []const u8) !SelectList {
    const sel = findSelectKeyword(statement) orelse return error.NoSelect;

    // Skip past `SELECT`, then any `DISTINCT` / `ALL` modifier.
    var i = sel + "SELECT".len;
    i = skipSpaces(statement, i);
    if (startsWithKeyword(statement, i, "DISTINCT")) i = skipSpaces(statement, i + "DISTINCT".len);
    if (startsWithKeyword(statement, i, "ALL")) i = skipSpaces(statement, i + "ALL".len);

    const list_start = i;
    const list_end = findListEnd(statement, list_start);

    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(allocator);

    // Split the list on top-level commas.
    var seg_start = list_start;
    var depth: i32 = 0;
    var j = list_start;
    while (j < list_end) {
        switch (statement[j]) {
            '\'', '"', '`', '[' => {
                // Commas inside a quoted run do not split.
                j = skipQuoted(statement, j);
            },
            '(' => {
                depth += 1;
                j += 1;
            },
            ')' => {
                depth -= 1;
                j += 1;
            },
            ',' => {
                if (depth == 0) {
                    try pushItem(allocator, &items, statement[seg_start..j]);
                    seg_start = j + 1;
                }
                j += 1;
            },
            else => j += 1,
        }
    }
    try pushItem(allocator, &items, statement[seg_start..list_end]);

    if (items.items.len == 0) return error.EmptyList;
    return .{
        .items = try items.toOwnedSlice(allocator),
        .offset = list_start,
        .len = list_end - list_start,
        .rest = statement[list_end..],
    };
}

fn pushItem(
    allocator: Allocator,
    items: *std.ArrayList(Item),
    raw_untrimmed: []const u8,
) !void {
    const raw = std.mem.trim(u8, raw_untrimmed, " \t\r\n");
    if (raw.len == 0) return;
    // A fragment that is nothing but a comment is not a column.
    if (isOnlyComment(raw)) return;
    try items.append(allocator, parseItem(raw));
}

/// True when `s` contains no code outside comments and whitespace.
fn isOnlyComment(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (i + 1 < s.len and c == '-' and s[i + 1] == '-') {
            i = skipLineComment(s, i);
            continue;
        }
        if (i + 1 < s.len and c == '/' and s[i + 1] == '*') {
            i = skipBlockComment(s, i);
            continue;
        }
        return false;
    }
    return true;
}

/// Classify one already-trimmed select-list entry.
fn parseItem(raw: []const u8) Item {
    // `*`
    if (raw.len == 1 and raw[0] == '*') {
        return .{ .expr = raw, .name = raw, .is_star = true };
    }
    // `qualifier.*`
    if (std.mem.endsWith(u8, raw, ".*")) {
        const qual = raw[0 .. raw.len - 2];
        if (qual.len != 0 and isDottedQualifier(qual)) {
            return .{
                .expr = raw,
                .name = raw,
                .is_star = true,
                .star_qualifier = qual,
            };
        }
    }

    // `expr AS alias` — the explicit, unambiguous form.
    if (findTopLevelAs(raw)) |as_idx| {
        const alias = unquote(std.mem.trim(u8, raw[as_idx + 2 ..], " \t\r\n"));
        if (alias.len != 0) return .{ .expr = raw, .name = alias };
    }

    // `expr alias` — a bare trailing alias.
    if (findBareAlias(raw)) |name| {
        return .{ .expr = raw, .name = name };
    }

    // A bare column reference is its own name.
    if (isPlainColumnRef(raw)) {
        return .{ .expr = raw, .name = raw };
    }

    // Anything else keeps its own text, matching SQLite's own CLI.
    return .{ .expr = raw, .name = raw };
}

/// Offset of a top-level ` AS ` (case-insensitive) in `s`, or null.
fn findTopLevelAs(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '\'', '"', '`', '[' => {
                i = skipQuoted(s, i);
                continue;
            },
            '(' => {
                depth += 1;
                continue;
            },
            ')' => {
                depth -= 1;
                continue;
            },
            else => {},
        }
        if (depth != 0) continue;
        if (i + 2 > s.len) continue;
        if (!std.ascii.eqlIgnoreCase(s[i .. i + 2], "as")) continue;
        // Word boundaries: `has` and `xas` must not match.
        if (i > 0 and isWordByte(s[i - 1])) continue;
        const after = if (i + 2 < s.len) s[i + 2] else ' ';
        if (isWordByte(after)) continue;
        return i;
    }
    return null;
}

/// The alias of a bare `expr alias`, or null if there isn't one.
fn findBareAlias(raw: []const u8) ?[]const u8 {
    const last_space = lastTopLevelSpace(raw) orelse return null;
    const alias = raw[last_space + 1 ..];
    if (!isPlainIdent(alias)) return null;

    // An operator immediately before the candidate means this is part of an expression, not an alias: `a + b` is not `a` aliased `b`.
    const prev_byte = if (last_space > 0) raw[last_space - 1] else 0;
    if (isOperatorByte(prev_byte)) return null;

    // The token before the alias must not itself be a clause boundary, or this is a two-word expression rather than an aliased one.
    const before = std.mem.trimEnd(u8, raw[0..last_space], " \t\r\n");
    const prev_space = lastTopLevelSpace(before) orelse return alias;
    const prev = before[prev_space + 1 ..];
    // `CASE ... END alias` — `END` closes the expression, not a clause.
    if (std.ascii.eqlIgnoreCase(prev, "END")) return alias;
    if (sqlmod.isReservedKeyword(prev)) return null;
    return alias;
}

/// Offset of the last top-level whitespace byte, or null.
fn lastTopLevelSpace(s: []const u8) ?usize {
    var depth: i32 = 0;
    var found: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '\'', '"', '`', '[' => {
                i = skipQuoted(s, i);
                continue;
            },
            '(' => {
                depth += 1;
                continue;
            },
            ')' => {
                depth -= 1;
                continue;
            },
            ' ', '\t', '\r', '\n' => {
                if (depth == 0) found = i;
                continue;
            },
            else => {},
        }
    }
    return found;
}

fn isPlainIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return !sqlmod.isReservedKeyword(s);
}

/// `a`, `a.b`, `a.b.c` — a possibly-qualified column reference.
fn isPlainColumnRef(s: []const u8) bool {
    if (s.len == 0) return false;
    var part_len: usize = 0;
    for (s) |c| {
        if (c == '.') {
            if (part_len == 0) return false;
            part_len = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
        part_len += 1;
    }
    if (part_len == 0) return false;
    // A multi-part name may legitimately end in a reserved word (`t.select` is legal), so only a bare reserved word is rejected.
    if (std.mem.indexOfScalar(u8, s, '.') == null and sqlmod.isReservedKeyword(s)) return false;
    return true;
}

fn isDottedQualifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return true;
}

/// Strip surrounding quotes from an alias: `"my col"` -> `my col`.
fn unquote(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const first = s[0];
    const last = s[s.len - 1];
    const matched = (first == '"' and last == '"') or
        (first == '`' and last == '`') or
        (first == '[' and last == ']');
    if (!matched) return s;
    return s[1 .. s.len - 1];
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Bytes that combine or compare operands.
fn isOperatorByte(c: u8) bool {
    return switch (c) {
        '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~' => true,
        else => false,
    };
}

fn skipSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    return i;
}

fn startsWithKeyword(s: []const u8, at: usize, kw: []const u8) bool {
    if (at + kw.len > s.len) return false;
    if (!std.ascii.eqlIgnoreCase(s[at .. at + kw.len], kw)) return false;
    if (at + kw.len < s.len and isWordByte(s[at + kw.len])) return false;
    return true;
}

/// Advance past a `--` line comment.
fn skipLineComment(s: []const u8, i: usize) usize {
    var j = i + 2;
    while (j < s.len and s[j] != '\n') j += 1;
    return j;
}

/// Advance past a `/* ... */` block comment, or to end of input.
fn skipBlockComment(s: []const u8, i: usize) usize {
    var j = i + 2;
    while (j + 1 < s.len) : (j += 1) {
        if (s[j] == '*' and s[j + 1] == '/') return j + 2;
    }
    return s.len;
}

/// Advance past a quoted run starting at `i`.
fn skipQuoted(s: []const u8, i: usize) usize {
    const open = s[i];
    const close: u8 = switch (open) {
        '[' => ']',
        else => open,
    };
    var j = i + 1;
    while (j < s.len) : (j += 1) {
        if (s[j] != close) continue;
        // A doubled quote is an escape, not the end.
        if (close != ']' and j + 1 < s.len and s[j + 1] == close) {
            j += 1;
            continue;
        }
        return j + 1;
    }
    return s.len;
}

/// Offset of the `SELECT` that begins the output list, or null.
fn findSelectKeyword(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        i = skipCommentOrSpace(s, i) orelse return null;
        if (i >= s.len) break;
        const c = s[i];
        if (c == '(') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            i += 1;
            continue;
        }
        if (isWordByte(c)) {
            var j = i;
            while (j < s.len and isWordByte(s[j])) j += 1;
            // The keyword that starts the output columns must be at depth 0; a `SELECT` inside a CTE subquery does not.
            if (depth == 0 and std.ascii.eqlIgnoreCase(s[i..j], "SELECT")) return i;
            i = j;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Advance past whitespace and comments. Returns null at end of input.
fn skipCommentOrSpace(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (std.ascii.isWhitespace(s[i])) {
            i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i] == '-' and s[i + 1] == '-') {
            while (i < s.len and s[i] != '\n') i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            i += 2;
            while (i + 1 < s.len and !(s[i] == '*' and s[i + 1] == '/')) i += 1;
            i = @min(i + 2, s.len);
            continue;
        }
        break;
    }
    return if (i < s.len) i else null;
}

/// Clauses that can follow a select list.
const list_terminators = [_][]const u8{
    "from",   "where", "group",  "having",    "order",  "limit",
    "offset", "union", "except", "intersect", "window", "returning",
};

/// Find where the select list ends: the first terminator keyword at depth 0, or the end of the statement.
fn findListEnd(s: []const u8, from: usize) usize {
    var depth: i32 = 0;
    var i = from;
    // End of the most recent item (or list element) seen so far.
    var item_end: usize = from;
    // True once at least one non-space character has been consumed, so a bare `*` still counts as an item.
    var seen_any = false;

    while (i < s.len) {
        // Comments are not items and must not terminate anything, so they are skipped before the character is classified.
        if (i + 1 < s.len and s[i] == '-' and s[i + 1] == '-') {
            i = skipLineComment(s, i);
            continue;
        }
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            i = skipBlockComment(s, i);
            continue;
        }

        const c = s[i];
        switch (c) {
            '\'', '"', '`', '[' => {
                i = skipQuoted(s, i);
                item_end = i;
                seen_any = true;
                continue;
            },
            '(' => {
                depth += 1;
                i += 1;
                seen_any = true;
                continue;
            },
            ')' => {
                // A `)` with no matching `(` ends the statement.
                if (depth == 0) return i;
                depth -= 1;
                i += 1;
                item_end = i;
                seen_any = true;
                continue;
            },
            ',' => {
                if (depth == 0) item_end = i + 1;
                i += 1;
                seen_any = true;
                continue;
            },
            ' ', '\t', '\r', '\n' => {
                i += 1;
                continue;
            },
            else => {},
        }

        if (depth != 0 or !isWordByte(c)) {
            // Punctuation inside an expression: `*`, `+`, `/`.
            i += 1;
            item_end = i;
            seen_any = true;
            continue;
        }

        // A word at depth 0.
        var j = i;
        while (j < s.len and isWordByte(s[j])) j += 1;
        const word = s[i..j];
        // A terminator keyword always ends the list at depth 0, even as the first token: `SELECT FROM t` has an empty select list, and naming a column `FROM`.
        if (!seen_any or i > item_end) {
            for (list_terminators) |term| {
                if (std.ascii.eqlIgnoreCase(word, term)) return item_end;
            }
        }
        item_end = j;
        seen_any = true;
        i = j;
    }
    return s.len;
}

// Tests

const testing = std.testing;

fn expectNames(statement: []const u8, expected: []const []const u8) !void {
    const list = try parse(testing.allocator, statement);
    defer list.deinit(testing.allocator);
    try testing.expectEqual(expected.len, list.items.len);
    for (expected, list.items) |e, it| try testing.expectEqualStrings(e, it.name);
}

test "bare column references are their own names" {
    try expectNames("SELECT id, name FROM t", &.{ "id", "name" });
    try expectNames("select A , B from t", &.{ "A", "B" });
}

test "qualified column references keep the full text" {
    try expectNames("SELECT u.id, u.name FROM users u", &.{ "u.id", "u.name" });
}

test "explicit AS alias wins" {
    try expectNames("SELECT COUNT(*) AS n FROM t", &.{"n"});
    try expectNames("SELECT a + b AS total FROM t", &.{"total"});
    try expectNames("SELECT x as Upper_X from t", &.{"Upper_X"});
}

test "bare trailing alias is honoured" {
    try expectNames("SELECT COUNT(*) n FROM t", &.{"n"});
    try expectNames("SELECT id, name nm FROM t", &.{ "id", "nm" });
}

test "CASE ... END alias works" {
    try expectNames("SELECT CASE WHEN a THEN 1 ELSE 0 END AS flag FROM t", &.{"flag"});
    try expectNames("SELECT CASE WHEN a THEN 1 ELSE 0 END flag FROM t", &.{"flag"});
}

test "quoted aliases are unwrapped" {
    try expectNames("SELECT x AS \"my col\" FROM t", &.{"my col"});
    try expectNames("SELECT x AS `my col` FROM t", &.{"my col"});
    try expectNames("SELECT x AS [my col] FROM t", &.{"my col"});
}

test "unaliased expressions keep their own text" {
    try expectNames("SELECT COUNT(*) FROM t", &.{"COUNT(*)"});
    try expectNames("SELECT a + b FROM t", &.{"a + b"});
}

test "reserved words are not mistaken for bare aliases" {
    try expectNames("SELECT x FROM t", &.{"x"});
    try expectNames("SELECT a, b WHERE c", &.{ "a", "b" });
}

test "a name containing a keyword is still a name" {
    try expectNames("SELECT has FROM t", &.{"has"});
    try expectNames("SELECT count FROM t", &.{"count"});
}

test "commas inside quotes and parens do not split" {
    try expectNames("SELECT f(a, b) AS s, c FROM t", &.{ "s", "c" });
    try expectNames("SELECT 'a,b' AS s FROM t", &.{"s"});
    try expectNames("SELECT g(x, (y, z)) AS s FROM t", &.{"s"});
}

test "star is flagged for expansion" {
    var list = try parse(testing.allocator, "SELECT * FROM t");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expect(list.items[0].is_star);
    try testing.expect(list.items[0].star_qualifier == null);
    try testing.expect(list.needsExpansion());
    try testing.expectEqual(@as(?usize, 0), list.firstStar());
}

test "qualified star carries its qualifier" {
    var list = try parse(testing.allocator, "SELECT u.* FROM users u");
    defer list.deinit(testing.allocator);
    try testing.expect(list.items[0].is_star);
    try testing.expectEqualStrings("u", list.items[0].star_qualifier.?);
}

test "star mixed with real columns" {
    var list = try parse(testing.allocator, "SELECT id, *, name FROM t");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("id", list.items[0].name);
    try testing.expect(list.items[1].is_star);
    try testing.expectEqualStrings("name", list.items[2].name);
    try testing.expectEqual(@as(?usize, 1), list.firstStar());
}

test "no star means no expansion needed" {
    var list = try parse(testing.allocator, "SELECT id, name FROM t");
    defer list.deinit(testing.allocator);
    try testing.expect(!list.needsExpansion());
    try testing.expectEqual(@as(?usize, null), list.firstStar());
}

test "DISTINCT and ALL modifiers are skipped" {
    try expectNames("SELECT DISTINCT name FROM t", &.{"name"});
    try expectNames("SELECT ALL id, name FROM t", &.{ "id", "name" });
}

test "WITH prefix resolves to the real select list" {
    try expectNames("WITH a AS (SELECT 1) SELECT id, a FROM t", &.{ "id", "a" });
    try expectNames("WITH a AS (SELECT z FROM s) SELECT id FROM t", &.{"id"});
}

test "EXPLAIN prefix resolves to the real select list" {
    try expectNames("EXPLAIN SELECT id FROM t", &.{"id"});
    try expectNames("EXPLAIN QUERY PLAN SELECT id FROM t", &.{"id"});
}

test "list boundaries: rest captures the tail for rewriting" {
    var list = try parse(testing.allocator, "SELECT a, b FROM t WHERE c = 1");
    defer list.deinit(testing.allocator);
    try testing.expectEqualStrings(" FROM t WHERE c = 1", list.rest);
    const stmt = "SELECT a, b FROM t WHERE c = 1";
    try testing.expectEqualStrings("a, b", stmt[list.offset..][0..list.len]);
}

test "rest is empty when there is no tail" {
    var list = try parse(testing.allocator, "SELECT a, b");
    defer list.deinit(testing.allocator);
    try testing.expectEqualStrings("", list.rest);
}

test "comments inside the select list do not confuse the split" {
    try expectNames("SELECT a, -- pick one\n b FROM t", &.{ "a", "b" });
}

test "error cases" {
    try testing.expectError(error.NoSelect, parse(testing.allocator, "VALUES (1, 2)"));
    try testing.expectError(error.EmptyList, parse(testing.allocator, "SELECT FROM t"));
    try testing.expectError(error.EmptyList, parse(testing.allocator, "SELECT -- nothing\n FROM t"));
}

test "terminators after each clause keyword" {
    // Every clause keyword must end the list, or the last column of a real query silently merges with the tail.
    const tails = [_][]const u8{
        " FROM t",     " WHERE c", " GROUP BY c",     " HAVING c",
        " ORDER BY c", " LIMIT 5", " UNION SELECT 1", " WINDOW w",
    };
    for (tails) |tail| {
        const stmt = try std.fmt.allocPrint(testing.allocator, "SELECT a, b{s}", .{tail});
        defer testing.allocator.free(stmt);
        var list = try parse(testing.allocator, stmt);
        defer list.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), list.items.len);
        try testing.expectEqualStrings(tail, list.rest);
    }
}

test "every returned name is a slice of the original statement" {
    // A property, not just a value check: names borrow from the input, so a result set needs no per-column allocation.
    const stmt = "SELECT COUNT(*) AS n, u.name, t.*, 1 + 2 FROM t";
    var list = try parse(testing.allocator, stmt);
    defer list.deinit(testing.allocator);
    for (list.items) |it| {
        try testing.expect(std.mem.indexOf(u8, stmt, it.name) != null);
    }
}
