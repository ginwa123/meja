//! Command-line argument parsing for meja.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What the user asked for.
pub const Invocation = union(enum) {
    /// Print help and exit successfully.
    help,
    /// Print the version and exit successfully.
    version,
    /// Open an interactive session on `path`.
    interactive: struct { path: []const u8 },
    /// Run one command non-interactively.
    command: struct {
        path: []const u8,
        command: Command,
    },
    /// Nothing to do (no arguments at all).
    none,

    pub fn databasePath(self: Invocation) ?[]const u8 {
        return switch (self) {
            .interactive => |i| i.path,
            .command => |c| c.path,
            else => null,
        };
    }
};

/// A non-interactive operation.
pub const Command = union(enum) {
    /// Run arbitrary SQL and print the result.
    sql: []const u8,
    /// List tables and views.
    list_tables,
    /// Describe one table's columns, indexes and DDL.
    describe: []const u8,
    /// Emit the full schema (DDL for every object).
    dump_schema,
    /// Read SQL from stdin and run it.
    read_stdin,

    pub fn label(self: Command) []const u8 {
        return switch (self) {
            .sql => "sql",
            .list_tables => "tables",
            .describe => "describe",
            .dump_schema => "schema",
            .read_stdin => "stdin",
        };
    }
};

pub const ParseError = error{
    /// A flag was given with no value.
    MissingValue,
    /// Two databases were named.
    UnexpectedArgument,
    /// `--describe` with no table.
    MissingTableName,
};

/// Parse `args` (excluding argv[0]).
pub fn parse(args: []const []const u8) ParseError!Invocation {
    var path: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        }
        if (std.mem.eql(u8, arg, "--tables") or std.mem.eql(u8, arg, "-t")) {
            return .{ .command = .{ .path = path orelse return error.UnexpectedArgument, .command = .list_tables } };
        }
        if (std.mem.eql(u8, arg, "--schema") or std.mem.eql(u8, arg, "-s")) {
            return .{ .command = .{ .path = path orelse return error.UnexpectedArgument, .command = .dump_schema } };
        }
        if (std.mem.eql(u8, arg, "--describe") or std.mem.eql(u8, arg, "-d")) {
            index += 1;
            if (index >= args.len) return error.MissingTableName;
            return .{ .command = .{
                .path = path orelse return error.UnexpectedArgument,
                .command = .{ .describe = args[index] },
            } };
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--command")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            return .{ .command = .{
                .path = path orelse return error.UnexpectedArgument,
                .command = .{ .sql = args[index] },
            } };
        }
        if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--stdin")) {
            return .{ .command = .{
                .path = path orelse return error.UnexpectedArgument,
                .command = .read_stdin,
            } };
        }
        if (arg.len > 0 and arg[0] == '-') {
            // An unknown flag is a typo, not a database name.
            return error.UnexpectedArgument;
        }
        if (path != null) return error.UnexpectedArgument;
        path = arg;
    }

    if (path) |p| return .{ .interactive = .{ .path = p } };
    return .none;
}

pub const usage =
    \\meja — a database browser for SQLite
    \\
    \\USAGE
    \\  meja <database> [options]
    \\
    \\  Open <database> and browse it. Use :memory: for a scratch database.
    \\
    \\OPTIONS
    \\  -c, --command <sql>   Run <sql>, print the result, and exit.
    \\  -t, --tables          List tables and views, then exit.
    \\  -d, --describe <name> Show one table's columns, indexes and DDL.
    \\  -s, --schema          Print the DDL of every object, then exit.
    \\      --stdin           Read SQL from stdin, run it, and exit.
    \\  -h, --help            Show this help.
    \\  -V, --version         Show the version.
    \\
    \\EXAMPLES
    \\  meja app.db                       Interactive session.
    \\  meja app.db -c "SELECT * FROM users LIMIT 10"
    \\  meja app.db -t                   List tables.
    \\  meja app.db -d users             Describe the users table.
    \\  sqlite3 dump.sql | meja app.db --stdin
    \\
    \\INTERACTIVE COMMANDS
    \\  .tables          List tables and views.
    \\  .schema [name]   Show DDL for one table, or all of it.
    \\  .describe <name> Columns, types and constraints.
    \\  .indexes <name>  Indexes on a table.
    \\  .count <name>    Number of rows in a table.
    \\  .limit <n>       Rows per page for the next query (default 200).
    \\  .width on|off    Print borders around results.
    \\  .help            List these commands.
    \\  .quit            Leave.
    \\
    \\Anything else is SQL. End a line with a semicolon to run it, or use
    \\a blank line to run a multi-line statement.
    \\
;

// Tests

const testing = std.testing;

test "no arguments asks for help" {
    try testing.expectEqual(Invocation.none, try parse(&.{}));
}

test "a database path opens an interactive session" {
    const got = try parse(&.{"app.db"});
    try testing.expectEqualStrings("app.db", got.databasePath().?);
    try testing.expect(got == .interactive);
}

test "help and version short-circuit" {
    try testing.expect((try parse(&.{"--help"})) == .help);
    try testing.expect((try parse(&.{"-h"})) == .help);
    try testing.expect((try parse(&.{"--version"})) == .version);
    try testing.expect((try parse(&.{"-V"})) == .version);
    // Even with a database in front of it.
    try testing.expect((try parse(&.{ "app.db", "--help" })) == .help);
}

test "-c runs one statement" {
    const got = try parse(&.{ "app.db", "-c", "SELECT 1" });
    try testing.expectEqualStrings("app.db", got.databasePath().?);
    try testing.expect(got == .command);
    switch (got) {
        .command => |c| try testing.expectEqualStrings("SELECT 1", c.command.sql),
        else => return error.TestUnexpectedResult,
    }
}

test "--command is the long form of -c" {
    const got = try parse(&.{ "app.db", "--command", "SELECT 1" });
    switch (got) {
        .command => |c| try testing.expectEqualStrings("SELECT 1", c.command.sql),
        else => return error.TestUnexpectedResult,
    }
}

test "flags that take a value reject a missing one" {
    try testing.expectError(error.MissingValue, parse(&.{ "app.db", "-c" }));
    try testing.expectError(error.MissingTableName, parse(&.{ "app.db", "-d" }));
}

test "flags that need a database reject running without one" {
    try testing.expectError(error.UnexpectedArgument, parse(&.{"-t"}));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "-c", "SELECT 1" }));
}

test "a second positional is an error, not a silent override" {
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "a.db", "b.db" }));
}

test "an unknown flag is rejected rather than treated as a path" {
    // Silently reading `--tabels` as a database name gives a baffling "unable to open database".
    try testing.expectError(error.UnexpectedArgument, parse(&.{"--tabels"}));
}

/// The `Command` variant a flag selects, for test assertions.
fn commandOf(inv: Invocation) ?Command {
    return switch (inv) {
        .command => |c| c.command,
        else => null,
    };
}

test "the listing flags" {
    try testing.expectEqual(Command.list_tables, commandOf(try parse(&.{ "a.db", "-t" })).?);
    try testing.expectEqual(Command.list_tables, commandOf(try parse(&.{ "a.db", "--tables" })).?);
    try testing.expectEqual(Command.dump_schema, commandOf(try parse(&.{ "a.db", "-s" })).?);
    try testing.expectEqual(Command.dump_schema, commandOf(try parse(&.{ "a.db", "--schema" })).?);
    try testing.expectEqual(Command.read_stdin, commandOf(try parse(&.{ "a.db", "--stdin" })).?);
    try testing.expectEqual(Command.read_stdin, commandOf(try parse(&.{ "a.db", "-" })).?);
}

test "describe carries the table name" {
    const got = try parse(&.{ "a.db", "-d", "users" });
    switch (got) {
        .command => |c| try testing.expectEqualStrings("users", c.command.describe),
        else => return error.TestUnexpectedResult,
    }
}

test "a single dash means stdin, not a file called -" {
    try testing.expectEqual(Command.read_stdin, commandOf(try parse(&.{ "a.db", "-" })).?);
}

test "paths may look like flags once quoted" {
    // A database genuinely named `-weird.db` is reachable via `./-weird.db`.
    const got = try parse(&.{"./-weird.db"});
    try testing.expectEqualStrings("./-weird.db", got.databasePath().?);
}

test "usage mentions every command it implements" {
    // Keeps the help text honest about the dot-commands.
    for ([_][]const u8{ ".tables", ".schema", ".describe", ".indexes", ".count", ".limit", ".width", ".quit" }) |c| {
        try testing.expect(std.mem.indexOf(u8, usage, c) != null);
    }
}
