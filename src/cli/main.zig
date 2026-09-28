//! meja — the command-line database browser.
//!
//! Frontend over `meja.core`. Contains no data-access logic of its own:
//! everything here is argument handling, presentation, and the read-eval
//! loop.
//!
//! The interactive session is a dot-command REPL rather than a full
//! TUI. That is a deliberate choice: it needs no display server, so the
//! same binary is testable in CI on Linux, macOS and Windows, and it
//! pipes cleanly into `less` or a file. The GUI frontend in `src/gui`
//! covers the interactive case.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const meja = @import("meja");
const database = @import("databases").database;
const query = @import("meja").query;
const schema = @import("meja").schema;
const sql = @import("meja").sql;

const args = @import("args.zig");
const format = @import("format.zig");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    const argv = try init.minimal.args.toSlice(gpa);
    const invocation = args.parse(argv[1..]) catch |err| {
        try out.print("meja: {s}\n\n", .{@errorName(err)});
        try out.writeAll(args.usage);
        try out.flush();
        std.process.exit(2);
    };

    switch (invocation) {
        .none, .help => try out.writeAll(args.usage),
        .version => try out.print("meja {s}\n", .{version}),
        .interactive => |i| try openSession(gpa, out, i.path),
        .command => |c| {
            const code = runCommand(gpa, io, out, c.path, c.command) catch |err| {
                try out.print("meja: {s}\n", .{@errorName(err)});
                try out.flush();
                std.process.exit(1);
            };
            try out.flush();
            if (code != 0) std.process.exit(code);
        },
    }
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// An open database plus the presentation state the REPL carries
/// between commands.
const Session = struct {
    gpa: Allocator,
    io: Io,
    db: database.Db,
    /// Rows per page. A browser that dumps a million rows is unusable, so
    /// this starts bounded and the user can raise it.
    limit: usize = query.Limit.default_page_size,
    borders: bool = true,
    /// The path as the user typed it, for the prompt.
    label: []const u8,
    /// True once the database has been written to, so `.quit` can warn.
    dirty: bool = false,

    fn deinit(self: *Session) void {
        self.db.deinit();
    }
};

fn openSession(gpa: Allocator, out: *Io.Writer, path: []const u8) !void {
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var session = Session{
        .gpa = gpa,
        .io = threaded.io(),
        .db = .{},
        .label = path,
    };
    // `init` takes a NUL-terminated path because it is handed to
    // sqlite3_open; an argv slice is not sentinel-terminated.
    const zpath = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    session.db.init(session.io, zpath) catch |err| {
        try out.print("meja: cannot open '{s}': {s}\n", .{ path, openErrorHint(err, path) });
        return;
    };
    defer session.deinit();

    try greet(out, &session);
    try repl(gpa, out, &session);
}

fn openErrorHint(err: anyerror, path: []const u8) []const u8 {
    _ = path;
    return switch (err) {
        error.DatabaseNotFound => "no such file — check the path",
        error.PermissionDenied => "permission denied",
        error.OpenFailed => "could not open",
        error.DiskFull => "disk full",
        error.DatabaseCorrupt => "the file is not a valid SQLite database",
        else => @errorName(err),
    };
}

fn greet(out: *Io.Writer, session: *Session) !void {
    const objects = schema.listObjects(session.gpa, &session.db, &.{ .table, .view }) catch {
        try out.print("meja {s} — connected to {s}\n", .{ version, session.label });
        return;
    };
    defer schema.freeObjects(session.gpa, objects);

    var tables: usize = 0;
    var views: usize = 0;
    for (objects) |o| {
        switch (o.kind) {
            .table => tables += 1,
            .view => views += 1,
            else => {},
        }
    }
    try out.print(
        "meja {s} — {s} ({d} table{s}, {d} view{s})\n",
        .{ version, session.label, tables, plural(tables), views, plural(views) },
    );
    try out.writeAll("Type .help for commands, .quit to exit.\n\n");
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// The read-eval loop.
///
/// Reads a statement, runs it, prints the result. Input is accumulated
/// until a `;` is seen, so a multi-line statement works naturally, and a
/// blank line on its own runs whatever has accumulated — which is how a
/// long query with no trailing semicolon gets sent.
fn repl(gpa: Allocator, out: *Io.Writer, session: *Session) !void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);

    // ONE reader for the whole session. Creating a new File.Reader per
    // line would drop everything already buffered past the newline, so a
    // piped script would lose all but its first line.
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_file: Io.File.Reader = .init(.stdin(), session.io, &stdin_buf);
    const input = &stdin_file.interface;

    // End of input detection.
    //
    // `takeDelimiterExclusive` yields an empty slice both for a blank
    // line and for end of input, and reports neither as an error, so a
    // loop that trusted it printed the prompt forever at the end of a
    // piped script. Two CONSECUTIVE empty reads is the discriminator: a
    // blank line inside a script is followed by more input, whereas EOF
    // keeps yielding nothing.
    var consecutive_empty: usize = 0;

    while (true) {
        const prompt: []const u8 = if (pending.items.len == 0) "meja> " else "  ...> ";
        try out.print("{s}", .{prompt});
        try out.flush();

        const line = input.takeDelimiterExclusive('\n') catch break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len == 0) {
            consecutive_empty += 1;
            if (consecutive_empty >= 2) {
                // EOF: run anything still pending so a piped script that
                // omits its final semicolon is not silently dropped.
                if (pending.items.len != 0) try runScript(gpa, out, session, pending.items);
                break;
            }
        } else {
            consecutive_empty = 0;
        }

        // A dot-command only counts when nothing is half-entered.
        if (pending.items.len == 0 and trimmed.len != 0 and trimmed[0] == '.') {
            if (try dotCommand(gpa, out, session, trimmed)) return; // .quit
            continue;
        }
        if (pending.items.len == 0 and trimmed.len == 0) continue;

        if (pending.items.len != 0) try pending.append(gpa, '\n');
        try pending.appendSlice(gpa, trimmed);

        // Run on a trailing semicolon, or on a blank line (which is how
        // a long query with no semicolon gets sent).
        const ends_statement = pending.items.len != 0 and
            pending.items[pending.items.len - 1] == ';';
        if (!ends_statement and trimmed.len != 0) continue;

        const text_in = gpa.dupe(u8, pending.items) catch return error.OutOfMemory;
        pending.clearRetainingCapacity();
        try runScript(gpa, out, session, text_in);
    }
}

/// Run a script, one statement at a time.
///
/// The splitting is the app's own: the binding runs only the first
/// statement of a multi-statement string, so a script that "worked" would
/// silently drop everything after the first `;`.
fn runScript(gpa: Allocator, out: *Io.Writer, session: *Session, text: []const u8) !void {
    const statements = sql.splitStatements(gpa, text) catch return;
    defer sql.freeStatements(gpa, statements);

    for (statements) |statement| {
        try runOne(gpa, out, session, statement.text);
    }
}

fn runOne(gpa: Allocator, out: *Io.Writer, session: *Session, statement: []const u8) !void {
    var result = query.run(gpa, &session.db, statement, .{ .limit = .{ .rows = session.limit } }) catch |err| {
        try out.print("error: {s}\n", .{@errorName(err)});
        return;
    };
    defer result.deinit();

    if (result.error_message) |message| {
        try out.print("error: {s}\n", .{message});
        return;
    }
    if (result.rows_affected != 0) {
        session.dirty = true;
        try out.print("-- {d} row{s} affected\n", .{ result.rows_affected, plural(@intCast(result.rows_affected)) });
    }
    if (result.columnCount() == 0) return;
    try format.renderTable(out, gpa, &result, .{ .borders = session.borders });
}

/// Handle a dot-command. Returns true when the session should end.
fn dotCommand(gpa: Allocator, out: *Io.Writer, session: *Session, line: []const u8) !bool {
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const command = parts.next() orelse return false;

    if (std.mem.eql(u8, command, ".quit") or std.mem.eql(u8, command, ".exit")) {
        if (session.dirty) {
            try out.writeAll("(session had uncommitted work; SQLite files are written as you go)\n");
        }
        try out.writeAll("bye\n");
        return true;
    }
    if (std.mem.eql(u8, command, ".help")) {
        try out.writeAll(args.usage);
        return false;
    }
    if (std.mem.eql(u8, command, ".tables")) {
        try listTables(gpa, out, session);
        return false;
    }
    if (std.mem.eql(u8, command, ".schema")) {
        const name = parts.next();
        try showSchema(gpa, out, session, name);
        return false;
    }
    if (std.mem.eql(u8, command, ".describe")) {
        const name = parts.next() orelse {
            try out.writeAll(".describe needs a table name\n");
            return false;
        };
        try describeTable(gpa, out, session, name);
        return false;
    }
    if (std.mem.eql(u8, command, ".indexes")) {
        const name = parts.next() orelse {
            try out.writeAll(".indexes needs a table name\n");
            return false;
        };
        try listIndexes(gpa, out, session, name);
        return false;
    }
    if (std.mem.eql(u8, command, ".count")) {
        const name = parts.next() orelse {
            try out.writeAll(".count needs a table name\n");
            return false;
        };
        const n = schema.countRows(gpa, &session.db, name) catch |err| {
            try out.print("error: {s}\n", .{@errorName(err)});
            return false;
        };
        try out.print("{d}\n", .{n});
        return false;
    }
    if (std.mem.eql(u8, command, ".limit")) {
        const value = parts.next() orelse {
            try out.print("limit is {d}\n", .{session.limit});
            return false;
        };
        const n = std.fmt.parseInt(usize, value, 10) catch {
            try out.print("'{s}' is not a number\n", .{value});
            return false;
        };
        session.limit = if (n == 0) query.Limit.default_page_size else n;
        try out.print("limit is {d}\n", .{session.limit});
        return false;
    }
    if (std.mem.eql(u8, command, ".width")) {
        const value = parts.next() orelse "off";
        if (std.mem.eql(u8, value, "on")) {
            session.borders = true;
        } else {
            session.borders = false;
        }
        try out.print("borders {s}\n", .{if (session.borders) "on" else "off"});
        return false;
    }

    try out.print("unknown command '{s}' — try .help\n", .{command});
    return false;
}

fn listTables(gpa: Allocator, out: *Io.Writer, session: *Session) !void {
    const objects = schema.listObjects(gpa, &session.db, &.{ .table, .view }) catch |err| {
        try out.print("error: {s}\n", .{@errorName(err)});
        return;
    };
    defer schema.freeObjects(gpa, objects);

    if (objects.len == 0) {
        try out.writeAll("no tables\n");
        return;
    }
    for (objects) |o| {
        // Only tables and views were requested, but a view has no
        // reliable count, so neither is counted here: `COUNT(*)` on a
        // large table is a real query and this is a listing.
        try out.print("{s}\t{s}\n", .{ o.name, if (o.kind == .view) "view" else "table" });
    }
}

fn showSchema(gpa: Allocator, out: *Io.Writer, session: *Session, name: ?[]const u8) !void {
    const objects = schema.listObjects(gpa, &session.db, null) catch |err| {
        try out.print("error: {s}\n", .{@errorName(err)});
        return;
    };
    defer schema.freeObjects(gpa, objects);

    var printed: usize = 0;
    for (objects) |o| {
        if (name) |want| {
            if (!std.mem.eql(u8, o.name, want)) continue;
        }
        // An implicit index has NULL DDL; there is nothing to show.
        if (o.sql.len == 0) continue;
        if (printed != 0) try out.writeAll("\n");
        try out.writeAll(o.sql);
        try out.writeAll(";\n");
        printed += 1;
    }
    if (printed == 0) {
        if (name) |want| try out.print("no such object: {s}\n", .{want});
    }
}

fn describeTable(gpa: Allocator, out: *Io.Writer, session: *Session, name: []const u8) !void {
    const columns = schema.listColumns(gpa, &session.db, name) catch |err| {
        try out.print("error: {s}\n", .{@errorName(err)});
        return;
    };
    defer schema.freeColumns(gpa, columns);

    if (columns.len == 0) {
        try out.print("no such table: {s}\n", .{name});
        return;
    }
    try out.print("{d} column{s} in {s}\n\n", .{ columns.len, plural(columns.len), name });

    for (columns) |c| {
        try out.writeAll("  ");
        try out.print("{s}", .{c.name});
        if (c.declared_type.len != 0) try out.print(" {s}", .{c.declared_type});
        if (c.not_null) try out.writeAll(" NOT NULL");
        if (c.pk_position > 0) try out.print(" PRIMARY KEY ({d})", .{c.pk_position});
        if (c.default_value) |d| try out.print(" DEFAULT {s}", .{d});
        try out.writeByte('\n');
    }

    try out.writeByte('\n');
    try listIndexes(gpa, out, session, name);
}

fn listIndexes(gpa: Allocator, out: *Io.Writer, session: *Session, name: []const u8) !void {
    const indexes = schema.listIndexes(gpa, &session.db, name) catch |err| {
        try out.print("error: {s}\n", .{@errorName(err)});
        return;
    };
    defer schema.freeIndexes(gpa, indexes);
    if (indexes.len == 0) return;
    for (indexes) |ix| {
        try out.print("  index {s}{s}{s}\n", .{
            ix.name,
            if (ix.unique) " UNIQUE" else "",
            if (ix.partial) " PARTIAL" else "",
        });
    }
}

// ---------------------------------------------------------------------------
// Non-interactive commands
// ---------------------------------------------------------------------------

/// Returns the process exit code: 0 on success, 1 if a statement failed.
fn runCommand(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    command: args.Command,
) !u8 {
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var session = Session{ .gpa = gpa, .io = threaded.io(), .db = .{}, .label = path };
    // `init` takes a NUL-terminated path because it is handed to
    // sqlite3_open; an argv slice is not sentinel-terminated.
    const zpath = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    session.db.init(session.io, zpath) catch |err| {
        try out.print("meja: cannot open '{s}': {s}\n", .{ path, openErrorHint(err, path) });
        return 1;
    };
    defer session.deinit();

    switch (command) {
        .list_tables => {
            try listTables(gpa, out, &session);
        },
        .dump_schema => try showSchema(gpa, out, &session, null),
        .describe => |name| try describeTable(gpa, out, &session, name),
        .sql => |text| {
            const statements = sql.splitStatements(gpa, text) catch return 1;
            defer sql.freeStatements(gpa, statements);
            for (statements) |st| {
                const code = try runOneQuiet(gpa, out, &session, st.text);
                if (code != 0) return code;
            }
        },
        .read_stdin => {
            const text = readAllStdin(gpa, io) catch return 1;
            try runScript(gpa, out, &session, text);
        },
    }
    return 0;
}

/// Like `runOne` but reports a failure through the exit code instead of
/// only the message, so a script can be used in a pipeline.
fn runOneQuiet(gpa: Allocator, out: *Io.Writer, session: *Session, statement: []const u8) !u8 {
    var result = query.run(gpa, &session.db, statement, .{ .limit = .{ .rows = session.limit } }) catch {
        return 1;
    };
    defer result.deinit();

    if (result.error_message) |message| {
        try out.print("error: {s}\n", .{message});
        return 1;
    }
    if (result.rows_affected != 0) {
        try out.print("-- {d} row{s} affected\n", .{ result.rows_affected, plural(@intCast(result.rows_affected)) });
    }
    if (result.columnCount() != 0) {
        try format.renderTable(out, gpa, &result, .{ .borders = session.borders });
    }
    return 0;
}

fn readAllStdin(gpa: Allocator, io: Io) ![]const u8 {
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_file: Io.File.Reader = .init(.stdin(), io, &stdin_buf);
    const reader = &stdin_file.interface;
    // 64 MB cap: a browser that ingests an unbounded script into memory
    // is a denial of service against itself.
    return reader.allocRemaining(gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.InputTooLong,
        error.ReadFailed => error.ReadFailed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The CLI's own test surface. Without this the tests in args.zig and
// format.zig are never discovered by `zig build test`, because a test
// binary only walks the module reachable from its root file.
test {
    _ = args;
    _ = format;
}
