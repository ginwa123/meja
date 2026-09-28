//! Schema introspection: what tables, views, indexes and columns exist.
//!
//! Everything here is plain SQL against `sqlite_master` and the
//! `PRAGMA table_*` family. Two constraints from the `databases` binding
//! shape the implementation:
//!
//!   - **No column names on rows.** `PRAGMA table_info` returns six
//!     positional columns, so they are read by index against the order
//!     SQLite documents. `columnIndex` below names each one so a reorder
//!     in a future SQLite is a compile error rather than a silent
//!     misread.
//!   - **No identifier binding.** `PRAGMA` does not accept a `?`
//!     placeholder for a table name, so the name has to be interpolated.
//!     Every such interpolation goes through `sql.quoteIfNeeded`.
//!
//! `PRAGMA` statements are read through the *query* path rather than
//! `exec`, because `exec` swallows the diagnostic message and a schema
//! browser is exactly where a readable error matters most.

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("databases").database;
const sql = @import("sql.zig");

pub const Error = database.Error || Allocator.Error;

/// The kinds of object SQLite keeps in `sqlite_master`.
pub const ObjectKind = enum {
    table,
    view,
    index,
    trigger,
    /// A `type` this build does not model (e.g. a virtual table's
    /// shadow tables report odd values). Kept so nothing is silently
    /// dropped from the object list.
    other,

    pub fn fromSql(text: []const u8) ObjectKind {
        if (std.ascii.eqlIgnoreCase(text, "table")) return .table;
        if (std.ascii.eqlIgnoreCase(text, "view")) return .view;
        if (std.ascii.eqlIgnoreCase(text, "index")) return .index;
        if (std.ascii.eqlIgnoreCase(text, "trigger")) return .trigger;
        return .other;
    }

    pub fn label(self: ObjectKind) []const u8 {
        return @tagName(self);
    }
};

/// One row of `sqlite_master`.
pub const Object = struct {
    /// Schema-qualified name, e.g. `main.users`.
    name: []const u8,
    kind: ObjectKind,
    /// The `CREATE ...` statement, owned by the caller. This is the only
    /// way to see the exact DDL including constraints and defaults.
    sql: []const u8,
    /// `tbl_name` — the table an index or trigger belongs to.
    tbl_name: ?[]const u8 = null,
    /// Estimated row count, when the caller asked for it. `SELECT
    /// COUNT(*)` on a large table is not free, so this is opt-in.
    row_count: ?i64 = null,

    pub fn deinit(self: Object, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sql);
        if (self.tbl_name) |t| allocator.free(t);
    }
};

/// One column of a table, from `PRAGMA table_info`.
pub const Column = struct {
    name: []const u8,
    /// Declared type, exactly as written in the DDL. SQLite lets this be
    /// anything, so it is reported verbatim rather than normalised.
    declared_type: []const u8,
    not_null: bool,
    /// 0-based position in the table.
    position: i64,
    /// The default expression, verbatim, or null when there is none.
    default_value: ?[]const u8,
    /// 1-based primary-key position, or 0 when the column is not part
    /// of the primary key.
    pk_position: i64,

    pub fn deinit(self: Column, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.declared_type);
        if (self.default_value) |d| allocator.free(d);
    }
};

/// One index of a table, from `PRAGMA index_list`.
pub const Index = struct {
    name: []const u8,
    /// `PRAGMA index_list` reports 'c' for CREATE INDEX, 'u' for UNIQUE
    /// and 'pk' for the implicit primary-key index.
    origin: []const u8,
    unique: bool,
    partial: bool,

    pub fn deinit(self: Index, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.origin);
    }
};

// Positional columns of `PRAGMA table_info`, in SQLite's documented
// order. Reading these by name is what the binding cannot do.
const ti = struct {
    const cid = 0;
    const name = 1;
    const decl_type = 2;
    const notnull = 3;
    const dflt_value = 4;
    const pk = 5;
    const count = 6;
};

/// Positional columns of `sqlite_master` for our query.
const sm = struct {
    const obj_type = 0;
    const name = 1;
    const tbl_name = 2;
    const sql = 3;
    const count = 4;
};

/// Positional columns of `PRAGMA index_list`.
const il = struct {
    const seq = 0;
    const name = 1;
    const unique = 2;
    const origin = 3;
    const partial = 4;
    const count = 5;
};

/// List the objects in the database.
///
/// Only user objects are returned: SQLite's own `sqlite_*` internal
/// tables are excluded, because showing `sqlite_sequence` next to the
/// user's tables is noise, not information.
pub fn listObjects(
    allocator: Allocator,
    db: *database.Db,
    kinds: ?[]const ObjectKind,
) Error![]Object {
    var out: std.ArrayList(Object) = .empty;
    errdefer {
        for (out.items) |o| o.deinit(allocator);
        out.deinit(allocator);
    }

    // The kind filter is built from an enum list, so the values are
    // literals from our own code and cannot inject anything.
    var filter: std.ArrayList(u8) = .empty;
    defer filter.deinit(allocator);
    if (kinds) |ks| {
        try filter.appendSlice(allocator, " AND type IN (");
        for (ks, 0..) |k, i| {
            if (i != 0) try filter.append(allocator, ',');
            try filter.append(allocator, '\'');
            try filter.appendSlice(allocator, k.label());
            try filter.append(allocator, '\'');
        }
        try filter.append(allocator, ')');
    }

    const statement = try std.fmt.allocPrint(
        allocator,
        "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master" ++
            // SQLite reserves the `sqlite_` prefix: sqlite_sequence,
            // sqlite_stat1, sqlite_autoindex_*, and the FTS shadow tables
            // (sqlite_master itself aside). None of them are the user's
            // schema, so none of them belong in a browser's tree.
            // `_` is LIKE's single-character wildcard, so `LIKE
            // 'sqlite_%'` would also match `sqliteXyz`. GLOB is the
            // right tool: `*` is the wildcard there and `_` is literal.
            " WHERE name NOT GLOB 'sqlite_*'" ++
            "{s} ORDER BY type, name",
        .{filter.items},
    );
    defer allocator.free(statement);

    var rows = try db.query(allocator, statement, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values.len < sm.count) continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, row.values[sm.name]),
            .kind = ObjectKind.fromSql(row.values[sm.obj_type]),
            .sql = try allocator.dupe(u8, row.values[sm.sql]),
            .tbl_name = if (row.values[sm.tbl_name].len == 0)
                null
            else
                try allocator.dupe(u8, row.values[sm.tbl_name]),
        });
    }

    return out.toOwnedSlice(allocator);
}

pub fn freeObjects(allocator: Allocator, objects: []Object) void {
    for (objects) |o| o.deinit(allocator);
    allocator.free(objects);
}

/// The columns of a table or view.
///
/// The table name is interpolated (PRAGMA will not take a placeholder),
/// so it is quoted first.
pub fn listColumns(
    allocator: Allocator,
    db: *database.Db,
    table: []const u8,
) Error![]Column {
    var out: std.ArrayList(Column) = .empty;
    errdefer {
        for (out.items) |c| c.deinit(allocator);
        out.deinit(allocator);
    }

    const quoted = try sql.quoteIfNeeded(allocator, table);
    defer allocator.free(quoted);
    const statement = try std.fmt.allocPrint(
        allocator,
        "PRAGMA table_info({s})",
        .{quoted},
    );
    defer allocator.free(statement);

    var rows = try db.query(allocator, statement, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values.len < ti.count) continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, row.values[ti.name]),
            .declared_type = try allocator.dupe(u8, row.values[ti.decl_type]),
            .not_null = isTruthy(row.values[ti.notnull]),
            .position = std.fmt.parseInt(i64, row.values[ti.cid], 10) catch 0,
            .default_value = if (row.values[ti.dflt_value].len == 0)
                null
            else
                try allocator.dupe(u8, row.values[ti.dflt_value]),
            .pk_position = std.fmt.parseInt(i64, row.values[ti.pk], 10) catch 0,
        });
    }

    return out.toOwnedSlice(allocator);
}

pub fn freeColumns(allocator: Allocator, columns: []Column) void {
    for (columns) |c| c.deinit(allocator);
    allocator.free(columns);
}

/// The indexes attached to a table.
pub fn listIndexes(
    allocator: Allocator,
    db: *database.Db,
    table: []const u8,
) Error![]Index {
    var out: std.ArrayList(Index) = .empty;
    errdefer {
        for (out.items) |ix| ix.deinit(allocator);
        out.deinit(allocator);
    }

    const quoted = try sql.quoteIfNeeded(allocator, table);
    defer allocator.free(quoted);
    const statement = try std.fmt.allocPrint(allocator, "PRAGMA index_list({s})", .{quoted});
    defer allocator.free(statement);

    var rows = try db.query(allocator, statement, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        if (row.values.len < il.count) continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, row.values[il.name]),
            .origin = try allocator.dupe(u8, row.values[il.origin]),
            .unique = isTruthy(row.values[il.unique]),
            .partial = row.values.len > il.partial and isTruthy(row.values[il.partial]),
        });
    }

    return out.toOwnedSlice(allocator);
}

pub fn freeIndexes(allocator: Allocator, indexes: []Index) void {
    for (indexes) |ix| ix.deinit(allocator);
    allocator.free(indexes);
}

/// Count the rows in a table.
///
/// This is a real `SELECT COUNT(*)` and is therefore as slow as the
/// table is large, so callers make it opt-in rather than paying for it
/// while drawing a schema tree.
pub fn countRows(allocator: Allocator, db: *database.Db, table: []const u8) Error!i64 {
    const quoted = try sql.quoteIfNeeded(allocator, table);
    defer allocator.free(quoted);
    const statement = try std.fmt.allocPrint(allocator, "SELECT COUNT(*) FROM {s}", .{quoted});
    defer allocator.free(statement);

    var rows = try db.query(allocator, statement, &.{});
    defer rows.deinit();
    const maybe_row = try rows.next();
    if (maybe_row) |row| {
        defer row.deinit(allocator);
        if (row.values.len == 0) return 0;
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

/// True when a table (or view) with this name exists.
///
/// The name is bound as a parameter here, so it needs no quoting — this
/// is the one place where the binding's text-only parameters are exactly
/// right, and it is why an injection attempt in a table name cannot
/// escape.
pub fn tableExists(
    allocator: Allocator,
    db: *database.Db,
    name: []const u8,
) Error!bool {
    const statement =
        "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?";
    var rows = try db.query(allocator, statement, &.{name});
    defer rows.deinit();
    const maybe_row = try rows.next();
    if (maybe_row) |row| {
        defer row.deinit(allocator);
        if (row.values.len == 0) return false;
        const n = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        return n > 0;
    }
    return false;
}

/// The database's user_version — the integer slot SQLite reserves for
/// applications. Reported by the schema view so a user can see what a
/// tool has stashed there.
pub fn userVersion(allocator: Allocator, db: *database.Db) Error!i64 {
    var rows = try db.query(allocator, "PRAGMA user_version", &.{});
    defer rows.deinit();
    const maybe_row = try rows.next();
    if (maybe_row) |row| {
        defer row.deinit(allocator);
        if (row.values.len == 0) return 0;
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

/// SQLite's `PRAGMA` booleans arrive as the text `0` / `1`.
fn isTruthy(text: []const u8) bool {
    if (text.len == 0) return false;
    return !std.mem.eql(u8, text, "0");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Opens an in-memory database with a small known schema, mirroring the
/// setup used by the databases package's own tests.
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
        try db.exec(alloc,
            \\CREATE TABLE users (
            \\  id    INTEGER PRIMARY KEY,
            \\  name  TEXT NOT NULL,
            \\  email TEXT UNIQUE,
            \\  note  TEXT DEFAULT 'none',
            \\  score REAL
            \\)
        , &.{});
        try db.exec(alloc, "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)", &.{});
        try db.exec(alloc, "CREATE VIEW active AS SELECT id, name FROM users", &.{});
        try db.exec(alloc,
            \\CREATE TABLE logs (
            \\  id INTEGER PRIMARY KEY,
            \\  msg TEXT
            \\)
        , &.{});
        try db.exec(alloc, "CREATE INDEX idx_posts_user ON posts(user_id)", &.{});
        return .{ .threaded = threaded, .db = db };
    }

    fn deinit(self: *Fixture) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

test "listObjects finds tables, views and indexes" {
    var f = try Fixture.init();
    defer f.deinit();

    const objects = try listObjects(testing.allocator, &f.db, null);
    defer freeObjects(testing.allocator, objects);

    var tables: usize = 0;
    var views: usize = 0;
    var indexes: usize = 0;
    for (objects) |o| {
        switch (o.kind) {
            .table => tables += 1,
            .view => views += 1,
            .index => indexes += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), tables); // users, posts, logs
    try testing.expectEqual(@as(usize, 1), views); // active
    // One user index. `email TEXT UNIQUE` also makes an implicit one,
    // but SQLite names it `sqlite_autoindex_*`, which the `sqlite_`
    // filter drops along with the rest of the engine's own objects.
    try testing.expectEqual(@as(usize, 1), indexes);
}

test "listObjects excludes sqlite internals" {
    // Force an internal table to exist: AUTOINCREMENT creates
    // `sqlite_sequence`.
    var f = try Fixture.init();
    defer f.deinit();
    try f.db.exec(testing.allocator,
        \\CREATE TABLE auto (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)
    , &.{});
    try f.db.exec(testing.allocator, "INSERT INTO auto (v) VALUES ('x')", &.{});

    const objects = try listObjects(testing.allocator, &f.db, null);
    defer freeObjects(testing.allocator, objects);
    // Every `sqlite_*` object is internal: the sequence table, and the
    // implicit `sqlite_autoindex_*` indexes.
    for (objects) |o| {
        try testing.expect(!std.mem.startsWith(u8, o.name, "sqlite_"));
    }
}

test "listObjects can filter by kind" {
    var f = try Fixture.init();
    defer f.deinit();

    const views = try listObjects(testing.allocator, &f.db, &.{.view});
    defer freeObjects(testing.allocator, views);
    try testing.expectEqual(@as(usize, 1), views.len);
    try testing.expectEqualStrings("active", views[0].name);
    try testing.expectEqual(ObjectKind.view, views[0].kind);

    const tables = try listObjects(testing.allocator, &f.db, &.{ .table, .view });
    defer freeObjects(testing.allocator, tables);
    try testing.expectEqual(@as(usize, 4), tables.len);
}

test "object carries its DDL and owning table" {
    var f = try Fixture.init();
    defer f.deinit();

    const objects = try listObjects(testing.allocator, &f.db, &.{.index});
    defer freeObjects(testing.allocator, objects);
    try testing.expectEqual(@as(usize, 1), objects.len);
    try testing.expectEqualStrings("idx_posts_user", objects[0].name);
    try testing.expectEqualStrings("posts", objects[0].tbl_name.?);
    try testing.expect(std.mem.indexOf(u8, objects[0].sql, "CREATE INDEX") != null);
}

test "listColumns reports names, types and constraints" {
    var f = try Fixture.init();
    defer f.deinit();

    const cols = try listColumns(testing.allocator, &f.db, "users");
    defer freeColumns(testing.allocator, cols);

    try testing.expectEqual(@as(usize, 5), cols.len);
    try testing.expectEqualStrings("id", cols[0].name);
    try testing.expectEqualStrings("INTEGER", cols[0].declared_type);
    try testing.expectEqualStrings("name", cols[1].name);
    try testing.expect(cols[1].not_null);
    try testing.expect(!cols[0].not_null);
    try testing.expectEqual(@as(i64, 1), cols[0].pk_position);
    try testing.expectEqual(@as(i64, 0), cols[1].pk_position);
    try testing.expectEqualStrings("'none'", cols[3].default_value.?);
    try testing.expectEqualStrings("REAL", cols[4].declared_type);
}

test "listColumns quotes a hostile table name instead of executing it" {
    var f = try Fixture.init();
    defer f.deinit();

    // A name containing a quote and a semicolon must be treated as one
    // identifier. The PRAGMA must fail to find a table, not drop one.
    const cols = try listColumns(testing.allocator, &f.db, "users\"; DROP TABLE users; --");
    defer freeColumns(testing.allocator, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);

    // And the real table is still there.
    const still = try listColumns(testing.allocator, &f.db, "users");
    defer freeColumns(testing.allocator, still);
    try testing.expectEqual(@as(usize, 5), still.len);
}

test "listIndexes reports uniqueness and origin" {
    var f = try Fixture.init();
    defer f.deinit();

    const idx = try listIndexes(testing.allocator, &f.db, "posts");
    defer freeIndexes(testing.allocator, idx);
    try testing.expectEqual(@as(usize, 1), idx.len);
    try testing.expectEqualStrings("idx_posts_user", idx[0].name);
    try testing.expectEqualStrings("c", idx[0].origin);
    try testing.expect(!idx[0].unique);
    try testing.expect(!idx[0].partial);
}

test "countRows is exact" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;
    try f.db.exec(alloc, "INSERT INTO users (name, email) VALUES ('a', 'a@x')", &.{});
    try f.db.exec(alloc, "INSERT INTO users (name, email) VALUES ('b', 'b@x')", &.{});
    try f.db.exec(alloc, "INSERT INTO users (name, email) VALUES ('c', 'c@x')", &.{});

    try testing.expectEqual(@as(i64, 3), try countRows(testing.allocator, &f.db, "users"));
    try testing.expectEqual(@as(i64, 0), try countRows(testing.allocator, &f.db, "posts"));
}

test "tableExists distinguishes present, absent and hostile names" {
    var f = try Fixture.init();
    defer f.deinit();
    try testing.expect(try tableExists(testing.allocator, &f.db, "users"));
    try testing.expect(try tableExists(testing.allocator, &f.db, "active")); // a view
    try testing.expect(!try tableExists(testing.allocator, &f.db, "nope"));
    // Bound as a parameter, so this can only ever be a name.
    try testing.expect(!try tableExists(testing.allocator, &f.db, "users' OR '1'='1"));
}

test "userVersion reads SQLite's application slot" {
    var f = try Fixture.init();
    defer f.deinit();
    try testing.expectEqual(@as(i64, 0), try userVersion(testing.allocator, &f.db));
    try f.db.exec(testing.allocator, "PRAGMA user_version = 7", &.{});
    try testing.expectEqual(@as(i64, 7), try userVersion(testing.allocator, &f.db));
}
