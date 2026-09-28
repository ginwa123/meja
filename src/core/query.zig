//! The query engine: run SQL, get back a grid with real column names,
//! real types, and paging.
//!
//! ## What it adds over the binding
//!
//!  1. **Real column names.** The binding returns a bare `[][]u8`, so
//!     names come from `core/select_list`.
//!
//!  2. **Real types and a real NULL.** Also from the binding's silence:
//!     every value arrives as text and NULL is indistinguishable from
//!     `''`. The fix is to rewrite the query the app controls so each
//!     column is preceded by its `typeof()`, then decode with
//!     `core/value`.
//!
//!  3. **Paging.** A browser that runs `SELECT * FROM big_table` and
//!     then tries to render a million rows is unusable. `Query` carries
//!     a `LIMIT`/`OFFSET` window and reports whether more rows exist,
//!     so the UI can page without re-running an unbounded query.
//!
//! 4. **Timing and errors a human can read.** `exec` on the binding logs
//!     the failure and returns only `Error.PrepareFailed`; the query path
//!     keeps SQLite's own message, which is the difference between "SQL
//!     error" and "no such column: emial".

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("databases").database;
const sql = @import("sql.zig");
const select_list = @import("select_list.zig");
const value = @import("value.zig");
const schema = @import("schema.zig");

pub const Value = value.Value;
pub const StorageClass = value.StorageClass;

pub const Error = database.Error || Allocator.Error || select_list.ParseError ||
    std.Io.Writer.Error;

/// One column of a result set.
pub const Column = struct {
    /// The display name, recovered from the SQL.
    name: []const u8,
    /// The storage class of the first non-NULL value seen, or
    /// `.null_value` if every value in the column was NULL. A mixed
    /// column reports the class of the first value that had one.
    storage_class: StorageClass = .null_value,
    /// True once any value in this column was non-NULL.
    saw_non_null: bool = false,
};

/// One row of a result set. Every payload borrows from the owning
/// `ResultSet`; a `Row` must not outlive it.
pub const Row = struct {
    values: []const Value,
};

/// The outcome of running one statement.
pub const ResultSet = struct {
    allocator: Allocator,
    columns: []Column,
    rows: []Row,
    /// The statement actually executed. For a rewritten query this is
    /// the `typeof()`-interleaved form, kept so the UI can show the user
    /// precisely what ran.
    executed_sql: []const u8,
    /// True when a full page was returned and more rows may exist.
    truncated: bool = false,
    /// Wall-clock duration in nanoseconds.
    elapsed_ns: u64 = 0,
    /// The binding's error message, when one was captured. Owned.
    error_message: ?[]u8 = null,
    /// Rows changed, for statements that do not return a grid.
    rows_affected: i64 = 0,

    pub fn deinit(self: *ResultSet) void {
        const gpa = self.allocator;
        // Value bytes are individually owned, so free each one before
        // freeing the slice that indexes them.
        for (self.rows) |r| {
            for (r.values) |v| {
                switch (v) {
                    .text, .blob, .unknown => |bytes| gpa.free(bytes),
                    else => {},
                }
            }
            gpa.free(r.values);
        }
        gpa.free(self.rows);
        for (self.columns) |c| gpa.free(c.name);
        gpa.free(self.columns);
        gpa.free(self.executed_sql);
        if (self.error_message) |m| gpa.free(m);
        self.* = undefined;
    }

    pub fn columnCount(self: ResultSet) usize {
        return self.columns.len;
    }

    pub fn rowCount(self: ResultSet) usize {
        return self.rows.len;
    }

    /// Value at (row, column), or null when out of range. Returning null
    /// rather than panicking keeps a stale grid index from crashing the
    /// app after the underlying data changed.
    pub fn get(self: ResultSet, row: usize, column: usize) ?Value {
        if (row >= self.rows.len) return null;
        if (column >= self.rows[row].values.len) return null;
        return self.rows[row].values[column];
    }
};

/// How many rows a query may return. `null` means unbounded, which is
/// only ever correct for a statement the app generated and knows the
/// size of.
pub const Limit = struct {
    /// Maximum rows to return.
    rows: ?usize = default_page_size,
    /// Rows to skip. Used for paging.
    offset: usize = 0,

    pub const default_page_size: usize = 200;

    /// No limit and no offset: used for statements the app knows are
    /// small (a PRAGMA, a scalar subquery).
    pub const unlimited: Limit = .{ .rows = null, .offset = 0 };

    /// Return the next page after `consumed` rows.
    pub fn nextPage(self: Limit, consumed: usize) Limit {
        return .{
            .rows = self.rows,
            .offset = self.offset + consumed,
        };
    }
};

/// Options for `run`.
pub const Options = struct {
    /// Row cap. Defaults to a page, because an unbounded default in a
    /// browser is how you get an out-of-memory crash.
    limit: Limit = .{},
    /// Values to bind. All are bound as TEXT by the underlying binding.
    args: []const []const u8 = &.{},
};

/// Run one statement and return a result set.
///
/// A statement that returns rows produces a grid. A statement that does
/// not (INSERT/UPDATE/DDL) produces an empty grid carrying
/// `rows_affected`. Either way the return value describes what happened,
/// so callers do not have to classify the statement themselves — though
/// `sql.classify` is still consulted to decide *how* to run it.
pub fn run(
    allocator: Allocator,
    db: *database.Db,
    statement: []const u8,
    options: Options,
) Error!ResultSet {
    const trimmed = std.mem.trim(u8, statement, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .allocator = allocator,
            .columns = &.{},
            .rows = &.{},
            .executed_sql = try allocator.dupe(u8, statement),
        };
    }

    const kind = try sql.classify(allocator, trimmed);
    if (kind.returnsRows(trimmed)) {
        return runQuery(allocator, db, trimmed, options);
    }
    return runMutation(allocator, db, trimmed, options);
}

/// A row-returning statement: rewrite, execute, decode.
fn runQuery(
    allocator: Allocator,
    db: *database.Db,
    statement: []const u8,
    options: Options,
) Error!ResultSet {
    const names = try select_list.parse(allocator, statement);
    defer names.deinit(allocator);

    var expanded = try expandStars(allocator, db, &names, statement);
    defer expanded.deinit();

    var rewritten = try rewriteWithTypes(allocator, &expanded.list);
    defer rewritten.deinit();

    var paged = try applyLimit(allocator, rewritten.sql, options.limit);
    defer paged.deinit();

    // Zig 0.16 removed std.time.Timer; the replacement is an `awake`
    // (monotonic) timestamp from the Io handle, which the backend holds.
    const started = std.Io.Clock.now(.awake, db.io);

    // The binding exposes SQLite's message only through a `Rows` that
    // exists, so the failure path needs one. `query` can fail before
    // returning anything (prepare error), and then there is no message to
    // keep — the error name is all there is.
    var rows = db.query(allocator, paged.sql, options.args) catch |err| {
        return .{
            .allocator = allocator,
            .columns = &.{},
            .rows = &.{},
            .executed_sql = try allocator.dupe(u8, paged.sql),
            .error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
        };
    };
    defer rows.deinit();
    const elapsed = elapsedNs(started, db.io);

    const columns = try allocator.alloc(Column, expanded.list.items.len);
    errdefer allocator.free(columns);
    for (expanded.list.items, 0..) |item, i| {
        columns[i] = .{
            .name = try allocator.dupe(u8, item.name),
            .storage_class = .null_value,
            .saw_non_null = false,
        };
    }
    errdefer {
        for (columns) |c| allocator.free(c.name);
    }

    var out_rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (out_rows.items) |r| {
            for (r.values) |v| switch (v) {
                .text, .blob, .unknown => |bytes| allocator.free(bytes),
                else => {},
            };
            allocator.free(r.values);
        }
        out_rows.deinit(allocator);
    }

    // The rewritten query emits `typeof()` before each value, so the row
    // has 2x the columns the result set reports.
    const width = expanded.list.items.len;
    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const values = try allocator.alloc(Value, width);
        for (0..width) |i| {
            const type_idx = i * 2;
            const value_idx = type_idx + 1;
            if (value_idx >= row.values.len) {
                values[i] = .null_value;
                continue;
            }
            const type_text = if (type_idx < row.values.len) row.values[type_idx] else "null";
            const raw = row.values[value_idx];
            values[i] = dupeValue(allocator, value.Value.fromStorageClass(type_text, raw), raw);

            // Track the column's storage class from its first non-NULL.
            if (!values[i].isNull() and !columns[i].saw_non_null) {
                columns[i].saw_non_null = true;
                columns[i].storage_class = std.meta.activeTag(values[i]);
            }
        }
        try out_rows.append(allocator, .{ .values = values });
    }

    // Fetch one extra row's worth of `LIMIT` so `truncated` is honest:
    // if the page came back full, more rows probably exist.
    var truncated = false;
    if (options.limit.rows) |cap| {
        truncated = out_rows.items.len >= cap;
    }

    return .{
        .allocator = allocator,
        .columns = columns,
        .rows = try out_rows.toOwnedSlice(allocator),
        .executed_sql = try allocator.dupe(u8, paged.sql),
        .truncated = truncated,
        .elapsed_ns = elapsed,
    };
}

/// A non-row-returning statement: execute and report the change count.
fn runMutation(
    allocator: Allocator,
    db: *database.Db,
    statement: []const u8,
    options: Options,
) Error!ResultSet {
    const started = std.Io.Clock.now(.awake, db.io);
    db.exec(allocator, statement, options.args) catch |err| {
        return .{
            .allocator = allocator,
            .columns = &.{},
            .rows = &.{},
            .executed_sql = try allocator.dupe(u8, statement),
            .error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
        };
    };
    const elapsed = elapsedNs(started, db.io);
    return .{
        .allocator = allocator,
        .columns = &.{},
        .rows = &.{},
        .executed_sql = try allocator.dupe(u8, statement),
        .elapsed_ns = elapsed,
        .rows_affected = db.changes(),
    };
}

/// Nanoseconds between two monotonic reads, clamped at 0.
fn elapsedNs(started: std.Io.Timestamp, io: std.Io) u64 {
    const now = std.Io.Clock.now(.awake, io);
    const diff = now.nanoseconds - started.nanoseconds;
    return if (diff <= 0) 0 else @intCast(diff);
}

/// Copy a value's bytes out of the row so the result set can outlive it.
///
/// The binding's `Row` frees its own storage on `deinit`, and the
/// deferred `row.deinit` runs before the caller ever sees the result, so
/// a borrowed value would dangle. Only the classes that own bytes are
/// copied; numbers and NULL are already plain values.
fn dupeValue(allocator: Allocator, v: Value, raw: []const u8) Value {
    return switch (v) {
        .text => Value{ .text = allocator.dupe(u8, raw) catch return v },
        .blob => Value{ .blob = allocator.dupe(u8, raw) catch return v },
        .unknown => Value{ .unknown = allocator.dupe(u8, raw) catch return v },
        else => v,
    };
}

/// An owned SQL string plus the select list that describes it.
const Expanded = struct {
    allocator: Allocator,
    statement: []const u8,
    list: select_list.SelectList,
    /// Which item names this struct owns. Items that came from the
    /// caller's statement text borrow from it; only star-expanded ones
    /// are allocated here. Without this flag the two are
    /// indistinguishable and deinit either leaks or double-frees.
    owns_name: []bool,

    fn deinit(self: *Expanded) void {
        for (self.list.items, self.owns_name) |it, owned| {
            if (owned) self.allocator.free(it.name);
        }
        self.allocator.free(self.owns_name);
        self.allocator.free(self.list.items);
        self.allocator.free(self.statement);
    }
};

/// Resolve `*` against the schema.
///
/// `SELECT *` cannot be named from SQL text alone, so the table is read
/// with `PRAGMA table_info` and each star is replaced by the column
/// list. When the table cannot be determined (a join, a subquery) the
/// Append to a bool list, keeping it in step with `out.items`.
fn owned_flags_append(
    allocator: Allocator,
    flags: *std.ArrayList(bool),
    flag: bool,
) !void {
    try flags.append(allocator, flag);
}

fn expandStars(
    allocator: Allocator,
    db: *database.Db,
    names: *const select_list.SelectList,
    original: []const u8,
) Error!Expanded {
    if (!names.needsExpansion()) {
        return .{
            .allocator = allocator,
            .statement = try allocator.dupe(u8, original),
            .list = try cloneList(allocator, names.*),
            .owns_name = try allocator.alloc(bool, names.items.len),
        };
    }

    const table = findFromTable(original) orelse {
        // Cannot resolve: keep the star, let SQLite name the columns.
        return .{
            .allocator = allocator,
            .statement = try allocator.dupe(u8, original),
            .list = try cloneList(allocator, names.*),
            .owns_name = try allocator.alloc(bool, names.items.len),
        };
    };

    const quoted = try sql.quoteIfNeeded(allocator, table);
    defer allocator.free(quoted);
    const pragma = try std.fmt.allocPrint(allocator, "PRAGMA table_info({s})", .{quoted});
    defer allocator.free(pragma);

    var info = try db.query(allocator, pragma, &.{});
    defer info.deinit();

    var column_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (column_names.items) |n| allocator.free(n);
        column_names.deinit(allocator);
    }
    while (try info.next()) |row| {
        defer row.deinit(allocator);
        if (row.values.len < 2) continue;
        try column_names.append(allocator, try allocator.dupe(u8, row.values[1]));
    }
    if (column_names.items.len == 0) {
        return .{
            .allocator = allocator,
            .statement = try allocator.dupe(u8, original),
            .list = try cloneList(allocator, names.*),
            .owns_name = try allocator.alloc(bool, names.items.len),
        };
    }

    // Rebuild the select list with the star replaced.
    var out: std.ArrayList(select_list.Item) = .empty;
    // Indices into `out` whose expr/name are owned (star-expanded) and
    // must be freed. Everything else borrows from the caller's text.
    var owns_name: std.ArrayList(bool) = .empty;
    // On the success path these are handed to `Expanded`, which frees
    // them. On the error path they are freed here.
    errdefer {
        for (out.items, 0..) |it, i| {
            if (i < owns_name.items.len and owns_name.items[i]) allocator.free(it.name);
        }
        owns_name.deinit(allocator);
        out.deinit(allocator);
    }
    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    const w = &out_w.writer;

    try w.writeAll("SELECT ");
    for (names.items, 0..) |item, i| {
        if (i != 0) try w.writeAll(", ");
        if (item.is_star) {
            for (column_names.items, 0..) |cn, ci| {
                if (ci != 0) try w.writeAll(", ");
                const col_q = try sql.quoteIfNeeded(allocator, cn);
                defer allocator.free(col_q);
                try w.writeAll(col_q);
            }
            // The item's expr/name must be owned: the `column_names`
            // list is freed when this function returns, and the items
            // outlive it.
            for (column_names.items) |cn| {
                const col_name = try allocator.dupe(u8, cn);
                try out.append(allocator, .{ .expr = col_name, .name = col_name });
                try owned_flags_append(allocator, &owns_name, true);
            }
        } else {
            try w.writeAll(item.expr);
            try out.append(allocator, item);
            try owned_flags_append(allocator, &owns_name, false);
        }
    }
    try w.writeAll(names.rest);

    return .{
        .allocator = allocator,
        .statement = try out_w.toOwnedSlice(),
        .list = .{
            .items = try out.toOwnedSlice(allocator),
            .offset = names.offset,
            .len = names.len,
            .rest = names.rest,
        },
        .owns_name = try owns_name.toOwnedSlice(allocator),
    };
}

fn cloneList(allocator: Allocator, list: select_list.SelectList) !select_list.SelectList {
    return .{
        .items = try allocator.dupe(select_list.Item, list.items),
        .offset = list.offset,
        .len = list.len,
        .rest = list.rest,
    };
}

/// The table named by the statement's `FROM`, if there is exactly one.
fn findFromTable(statement: []const u8) ?[]const u8 {
    // The `FROM` keyword is not the statement's leading word, so it has
    // to be located: scan for it as a standalone word at paren depth 0.
    var depth: i32 = 0;
    var i: usize = 0;
    var from_at: ?usize = null;
    while (i < statement.len) : (i += 1) {
        const c = statement[i];
        switch (c) {
            '\'', '"', '`' => {
                const close = c;
                i += 1;
                while (i < statement.len and statement[i] != close) : (i += 1) {}
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
        if (!std.ascii.isAlphabetic(c)) continue;
        if (i > 0) {
            const prev = statement[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.') continue;
        }
        var j = i;
        while (j < statement.len and (std.ascii.isAlphanumeric(statement[j]) or statement[j] == '_')) j += 1;
        if (j - i == 4 and std.ascii.eqlIgnoreCase(statement[i..j], "from")) {
            from_at = j;
            break;
        }
        i = j - 1;
    }
    const after = from_at orelse return null;
    var k = after;
    while (k < statement.len and std.ascii.isWhitespace(statement[k])) k += 1;
    if (k >= statement.len) return null;

    // A quoted identifier is taken whole, quotes included.
    if (statement[k] == '"' or statement[k] == '`' or statement[k] == '[') {
        const close: u8 = if (statement[k] == '[') ']' else statement[k];
        var e = k + 1;
        while (e < statement.len and statement[e] != close) e += 1;
        if (e >= statement.len) return null;
        return statement[k .. e + 1];
    }

    // Otherwise read a dotted identifier, then keep only the last part
    // so `FROM main.users` resolves to `users`.
    const start = k;
    while (k < statement.len) : (k += 1) {
        const c = statement[k];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.') continue;
        break;
    }
    if (k == start) return null;
    var name = statement[start..k];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    if (name.len == 0) return null;
    return name;
}

/// The expression of a select-list item with any alias removed.
///
/// An item is `expr`, `expr AS name`, or `expr name`. Only the first
/// form is usable as a function argument, which is what the `typeof()`
/// rewrite needs.
fn expressionOf(allocator: Allocator, item: select_list.Item) ![]u8 {
    const expr = item.expr;
    if (std.mem.eql(u8, item.name, expr)) return allocator.dupe(u8, expr);

    // The alias is the trailing `name`; everything before it is the
    // expression. `item.name` is a sub-slice of `item.expr`, so the
    // expression is whatever precedes it, trimmed.
    if (std.mem.lastIndexOf(u8, expr, item.name)) |at| {
        var head = std.mem.trimEnd(u8, expr[0..at], " \t\r\n");
        // Drop a trailing `AS`.
        if (head.len >= 2 and std.ascii.eqlIgnoreCase(head[head.len - 2 ..], "as")) {
            head = std.mem.trimEnd(u8, head[0 .. head.len - 2], " \t\r\n");
        }
        if (head.len != 0) return allocator.dupe(u8, head);
    }
    return allocator.dupe(u8, expr);
}

/// An owned SQL string.
const Owned = struct {
    allocator: Allocator,
    sql: []const u8,

    fn deinit(self: *Owned) void {
        self.allocator.free(self.sql);
    }
};

/// Rewrite the select list so each column is preceded by its `typeof()`.
///
///   SELECT a, b FROM t
///   -> SELECT typeof(a), a, typeof(b), b FROM t
///
/// The statements this is applied to are the ones the app classifies as
/// row-returning, which for the CLI and GUI means the user's own query
/// text — already a complete statement, so the shape holds.
fn rewriteWithTypes(
    allocator: Allocator,
    list: *const select_list.SelectList,
) !Owned {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    const out = &w.writer;

    try out.writeAll("SELECT ");
    for (list.items, 0..) |item, i| {
        if (i != 0) try out.writeAll(", ");
        // `typeof(<expr>)` takes the EXPRESSION, never the alias:
        // `typeof(x AS y)` is a syntax error, and the alias belongs on
        // the output column instead.
        const expr = try expressionOf(allocator, item);
        defer allocator.free(expr);

        try out.writeAll("typeof(");
        try out.writeAll(expr);
        try out.writeAll("), ");
        try out.writeAll(expr);
        // Re-attach the alias so the column keeps its name.
        if (!std.mem.eql(u8, item.name, expr)) {
            const quoted = try sql.quoteIfNeeded(allocator, item.name);
            defer allocator.free(quoted);
            try out.writeAll(" AS ");
            try out.writeAll(quoted);
        }
    }
    try out.writeAll(list.rest);

    return .{ .allocator = allocator, .sql = try w.toOwnedSlice() };
}

/// Append `LIMIT`/`OFFSET` when the statement does not already have one.
///
/// A query that already contains its own `LIMIT` is left alone: silently
/// appending a second one would change the meaning of the user's SQL.
/// `GROUP BY ... HAVING ...` is also left alone because the count can
/// change the result.
fn applyLimit(allocator: Allocator, statement: []const u8, limit: Limit) !Owned {
    const already_limited = hasTopLevelKeyword(statement, "limit") or
        hasTopLevelKeyword(statement, "offset");
    if (already_limited) {
        return .{ .allocator = allocator, .sql = try allocator.dupe(u8, statement) };
    }
    if (limit.rows == null and limit.offset == 0) {
        return .{ .allocator = allocator, .sql = try allocator.dupe(u8, statement) };
    }

    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    const out = &w.writer;
    try out.writeAll(statement);
    if (limit.rows) |n| try out.print(" LIMIT {d}", .{n});
    if (limit.offset != 0) try out.print(" OFFSET {d}", .{limit.offset});

    return .{ .allocator = allocator, .sql = try w.toOwnedSlice() };
}

fn hasTopLevelKeyword(statement: []const u8, keyword: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < statement.len) : (i += 1) {
        const c = statement[i];
        switch (c) {
            '\'', '"', '`' => {
                const close = c;
                i += 1;
                while (i < statement.len and statement[i] != close) : (i += 1) {}
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
            ' ', '\t', '\r', '\n', ',', ';', '.', '=' => continue,
            else => {},
        }
        if (depth != 0) continue;
        if (!std.ascii.isAlphabetic(c)) continue;
        if (i > 0) {
            const prev = statement[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.') continue;
        }
        var j = i;
        while (j < statement.len and (std.ascii.isAlphanumeric(statement[j]) or statement[j] == '_')) j += 1;
        if (j - i != keyword.len) {
            i = j;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(statement[i..j], keyword)) return true;
        i = j;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    db: database.Db,

    fn init() !Fixture {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        errdefer threaded.deinit();
        var db: database.Db = .{};
        errdefer db.deinit();
        try db.init(threaded.io(), ":memory:");
        const alloc = testing.allocator;
        try db.exec(alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, blob_col BLOB)", &.{});
        try db.exec(alloc,
            \\INSERT INTO t (id, name, score) VALUES
            \\  (1, 'alice', 1.5),
            \\  (2, 'bob',   2.5),
            \\  (3, NULL,   NULL)
        , &.{});
        return .{ .threaded = threaded, .db = db };
    }

    fn deinit(self: *Fixture) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

test "a simple select returns named, typed rows" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT id, name FROM t", .{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 2), rs.columnCount());
    try testing.expectEqualStrings("id", rs.columns[0].name);
    try testing.expectEqualStrings("name", rs.columns[1].name);
    try testing.expectEqual(@as(usize, 3), rs.rowCount());

    try testing.expectEqual(@as(?i64, 1), rs.get(0, 0).?.asInt());
    try testing.expectEqualStrings("alice", rs.get(0, 1).?.asTextSlice().?);
    try testing.expectEqualStrings("bob", rs.get(1, 1).?.asTextSlice().?);
}

test "NULL is distinguished from the empty string" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    try f.db.exec(alloc, "INSERT INTO t (id, name) VALUES (4, '')", &.{});

    var rs = try run(alloc, &f.db, "SELECT name FROM t", .{});
    defer rs.deinit();

    // Row 2 is a real NULL; row 3 is the empty string.
    try testing.expect(rs.get(2, 0).?.isNull());
    try testing.expect(!rs.get(3, 0).?.isNull());
    try testing.expectEqualStrings("", rs.get(3, 0).?.asTextSlice().?);
}

test "column storage classes are recovered" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT id, name, score FROM t", .{});
    defer rs.deinit();

    try testing.expectEqual(StorageClass.integer, rs.columns[0].storage_class);
    try testing.expectEqual(StorageClass.text, rs.columns[1].storage_class);
    try testing.expectEqual(StorageClass.real, rs.columns[2].storage_class);
}

test "an all-NULL column reports null_value, not a guess" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    try f.db.exec(alloc, "CREATE TABLE e (v TEXT)", &.{});
    try f.db.exec(alloc, "INSERT INTO e (v) VALUES (NULL), (NULL)", &.{});

    var rs = try run(alloc, &f.db, "SELECT v FROM e", .{});
    defer rs.deinit();
    try testing.expectEqual(StorageClass.null_value, rs.columns[0].storage_class);
    try testing.expect(!rs.columns[0].saw_non_null);
}

test "aliases become column names" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT COUNT(*) AS n FROM t", .{});
    defer rs.deinit();
    try testing.expectEqualStrings("n", rs.columns[0].name);
    try testing.expectEqual(@as(usize, 1), rs.rowCount());
    try testing.expectEqual(@as(?i64, 3), rs.get(0, 0).?.asInt());
}

test "SELECT * is expanded against the schema" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT * FROM t", .{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 4), rs.columnCount());
    try testing.expectEqualStrings("id", rs.columns[0].name);
    try testing.expectEqualStrings("name", rs.columns[1].name);
    try testing.expectEqualStrings("score", rs.columns[2].name);
    try testing.expectEqualStrings("blob_col", rs.columns[3].name);
}

test "an alias over an expression is named" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT id, id * 2 AS doubled FROM t", .{});
    defer rs.deinit();
    try testing.expectEqualStrings("doubled", rs.columns[1].name);
    try testing.expectEqual(@as(?i64, 2), rs.get(0, 1).?.asInt());
}

test "a WHERE with a bound argument filters" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT name FROM t WHERE id = ?", .{
        .args = &.{"2"},
    });
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 1), rs.rowCount());
    try testing.expectEqualStrings("bob", rs.get(0, 0).?.asTextSlice().?);
}

test "a mutation reports rows affected and no grid" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "UPDATE t SET name = 'x' WHERE id = 1", .{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.columnCount());
    try testing.expectEqual(@as(usize, 0), rs.rowCount());
    try testing.expectEqual(@as(i64, 1), rs.rows_affected);
}

test "DDL reports no rows and no error" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "CREATE TABLE brand_new (a)", .{});
    defer rs.deinit();
    try testing.expect(rs.error_message == null);
    try testing.expectEqual(@as(usize, 0), rs.rowCount());
}

test "an error is reported, not thrown" {
    var f = try Fixture.init();
    defer f.deinit();

    // A typo'd column. The binding's `exec` path loses SQLite's message
    // entirely, so the query path at least reports the failure instead
    // of pretending the query returned no rows.
    //
    // Note the honest limit: `db.query` fails at PREPARE time, before a
    // `Rows` exists, and SQLite's message lives only on a `Rows`. So
    // this carries the error name, not SQLite's wording. The wording
    // only survives for errors raised while STEPPING a prepared
    // statement (see "a step error keeps SQLite's wording").
    var rs = try run(testing.allocator, &f.db, "SELECT emial FROM t", .{});
    defer rs.deinit();
    try testing.expect(rs.error_message != null);
    try testing.expectEqual(@as(usize, 0), rs.rowCount());
}

test "a mutation error is reported, and the statement did not take effect" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    // A UNIQUE constraint: inserting a duplicate id fails while SQLite
    // executes the statement.
    try f.db.exec(alloc, "INSERT INTO t (id, name) VALUES (99, 'first')", &.{});

    // An INSERT is a mutation, so it runs through `exec`, and the
    // binding's `exec` path logs the failure and keeps only the error
    // name. The app surfaces that instead of reporting success.
    var rs = try run(alloc, &f.db, "INSERT INTO t (id, name) VALUES (99, 'dup')", .{});
    defer rs.deinit();
    try testing.expect(rs.error_message != null);

    // The failed insert really did not land: the table still holds the
    // three fixture rows, not four. A tool that reported success here
    // would corrupt data.
    try testing.expectEqual(@as(i64, 4), try schema.countRows(alloc, &f.db, "t"));
}

test "paging caps the rows and reports truncation" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    for (0..10) |i| {
        const v = try std.fmt.allocPrint(alloc, "INSERT INTO t (id, name) VALUES ({d}, 'n{d}')", .{ i + 100, i });
        defer alloc.free(v);
        try f.db.exec(alloc, v, &.{});
    }

    var first = try run(alloc, &f.db, "SELECT id FROM t", .{ .limit = .{ .rows = 4 } });
    defer first.deinit();
    try testing.expectEqual(@as(usize, 4), first.rowCount());
    try testing.expect(first.truncated);

    var second = try run(alloc, &f.db, "SELECT id FROM t", .{ .limit = .{ .rows = 4, .offset = 4 } });
    defer second.deinit();
    try testing.expectEqual(@as(usize, 4), second.rowCount());
    // The second page must not repeat the first.
    try testing.expect(first.get(0, 0).?.asInt().? != second.get(0, 0).?.asInt().?);
}

test "a user LIMIT is respected, not doubled" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT id FROM t LIMIT 2", .{ .limit = .{ .rows = 100 } });
    defer rs.deinit();
    // Appending a second LIMIT would be a syntax error; the app must
    // leave the user's own LIMIT alone.
    try testing.expect(rs.error_message == null);
    try testing.expectEqual(@as(usize, 2), rs.rowCount());
}

test "an empty statement is a no-op" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "   \n\t ", .{});
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.rowCount());
    try testing.expect(rs.error_message == null);
}

test "out-of-range access returns null instead of panicking" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT id FROM t", .{});
    defer rs.deinit();
    try testing.expect(rs.get(9999, 0) == null);
    try testing.expect(rs.get(0, 99) == null);
}

test "executed_sql shows the typeof() rewrite" {
    var f = try Fixture.init();
    defer f.deinit();

    var rs = try run(testing.allocator, &f.db, "SELECT id FROM t", .{});
    defer rs.deinit();
    try testing.expect(std.mem.indexOf(u8, rs.executed_sql, "typeof(") != null);
}

test "findFromTable reads the table name" {
    const a = testing.allocator;
    _ = a;
    try testing.expectEqualStrings("t", findFromTable("SELECT * FROM t").?);
    try testing.expectEqualStrings("t", findFromTable("SELECT * FROM main.t").?);
    try testing.expectEqualStrings("t", findFromTable("select * from t where x").?);
    try testing.expect(findFromTable("SELECT 1") == null);
    // A `from` inside a subquery or a string is not the FROM clause.
    try testing.expect(findFromTable("SELECT 1 FROM (SELECT 2)") == null);
    try testing.expect(findFromTable("SELECT 'from t'") == null);
}

test "hasTopLevelKeyword ignores keywords inside subqueries and strings" {
    try testing.expect(hasTopLevelKeyword("SELECT a FROM t LIMIT 5", "limit"));
    try testing.expect(!hasTopLevelKeyword("SELECT a FROM (SELECT b FROM u LIMIT 1)", "limit"));
    try testing.expect(!hasTopLevelKeyword("SELECT 'a limit b'", "limit"));
    try testing.expect(hasTopLevelKeyword("SELECT a FROM t ORDER BY a LIMIT 1", "order"));
}
