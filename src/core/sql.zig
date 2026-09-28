//! SQL text utilities: statement splitting, identifier quoting, and
//! statement classification.
//!
//! These exist because of a hard limitation in the underlying `databases`
//! (ruangsql) binding: it calls `sqlite3_prepare_v2` with a `NULL` tail
//! pointer, which means **only the first statement in a multi-statement
//! string is ever executed and the rest are silently discarded**. A query
//! pane that hands the user three statements and runs one of them is worse
//! than no pane at all, so the app splits first and runs each piece itself.
//!
//! The splitter is a small scanner rather than a `;` split because a naive
//! split breaks on all of the following, all of which are ordinary SQL:
//!
//!   - `SELECT ';' FROM t`            — semicolon inside a string literal
//!   - `SELECT "odd;name" FROM t`     — semicolon inside a quoted identifier
//!   - `SELECT 1 -- ; not a break`    — semicolon inside a line comment
//!   - `SELECT /* ; */ 1`             — semicolon inside a block comment
//!   - `CREATE TRIGGER ... BEGIN ...; ... END;`
//!                                  — semicolons inside a trigger body

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Scanner position class. Kept as a small enum so the main loop reads as
/// a state machine rather than a pile of boolean flags.
const State = enum {
    /// Ordinary SQL: looking for a statement terminator.
    code,
    /// Inside `'...'`; a doubled `''` is an escaped quote, not a terminator.
    single_quote,
    /// Inside `"..."`; a doubled `""` is an escaped quote.
    double_quote,
    /// Inside `` `...` `` (MySQL/SQLite alternative quoting).
    backtick_quote,
    /// Inside `[...]` (SQL Server style).
    bracket_quote,
    /// Inside `-- ...` up to the next newline.
    line_comment,
    /// Inside `/* ... */`.
    block_comment,
};

/// A statement broken out of a script. `text` slices directly into the
/// original script — it is not a copy, so it stays valid exactly as long
/// as the script buffer does.
pub const Statement = struct {
    /// 0-based index of this statement within the script.
    index: usize,
    /// The statement text, trimmed of surrounding whitespace.
    text: []const u8,
    /// 0-based byte offset of `text` within the original script.
    offset: usize,
};

/// Split a SQL script into individual statements.
///
/// Returns owned statement records; the `text` of each borrows from
/// `script`. Comments are preserved (SQL ignores them), but fragments
/// that contain nothing but whitespace and comments are dropped.
///
/// The caller owns the returned slice and must free it with
/// `freeStatements`; the `text` fields must not outlive `script`.
pub fn splitStatements(allocator: Allocator, script: []const u8) ![]Statement {
    var out: std.ArrayList(Statement) = .empty;
    errdefer out.deinit(allocator);

    var state: State = .code;
    var start: usize = 0; // where the current statement begins
    var i: usize = 0;

    // A trigger body is the one place where `;` is not a terminator.
    // We only start counting once the word `TRIGGER` has been seen, so
    // `BEGIN`/`END` inside an ordinary transaction (which is also a SQL
    // keyword pair) never affect splitting.
    var trigger_depth: i32 = 0;
    var in_trigger: bool = false;
    // Start offset of the word currently being scanned, so a word can be
    // classified at the exact moment its extent becomes known.
    var word_start: ?usize = null;

    while (i < script.len) : (i += 1) {
        const c = script[i];

        // Word bookkeeping runs first and only in code state, so a word
        // never spans a string or comment boundary.
        if (state == .code) {
            if (isWordByte(c)) {
                if (word_start == null) word_start = i;
            } else if (word_start) |ws| {
                classifyWord(script[ws..i], &in_trigger, &trigger_depth);
                word_start = null;
            }
        }

        switch (state) {
            .code => {
                switch (c) {
                    '\'' => state = .single_quote,
                    '"' => state = .double_quote,
                    '`' => state = .backtick_quote,
                    '[' => state = .bracket_quote,
                    // `--` starts a comment only when doubled.
                    '-' => if (i + 1 < script.len and script[i + 1] == '-') {
                        state = .line_comment;
                        i += 1;
                    },
                    '/' => if (i + 1 < script.len and script[i + 1] == '*') {
                        state = .block_comment;
                        i += 1;
                    },
                    else => {},
                }
                // A `;` is a terminator only outside strings/comments and
                // at trigger-body depth zero.
                if (c == ';' and state == .code and trigger_depth <= 0) {
                    const frag = std.mem.trim(u8, script[start..i], " \t\r\n");
                    if (isMeaningful(frag)) {
                        try out.append(allocator, .{
                            .index = out.items.len,
                            .text = frag,
                            .offset = @intFromPtr(frag.ptr) - @intFromPtr(script.ptr),
                        });
                    }
                    start = i + 1;
                    in_trigger = false;
                    trigger_depth = 0;
                    word_start = null;
                }
            },
            .single_quote => {
                if (c == '\'') {
                    // `''` is an escaped quote: stay inside the literal.
                    if (i + 1 < script.len and script[i + 1] == '\'') {
                        i += 1;
                    } else {
                        state = .code;
                    }
                }
            },
            .double_quote => {
                if (c == '"') {
                    if (i + 1 < script.len and script[i + 1] == '"') {
                        i += 1;
                    } else {
                        state = .code;
                    }
                }
            },
            .backtick_quote => if (c == '`') {
                state = .code;
            },
            .bracket_quote => if (c == ']') {
                state = .code;
            },
            .line_comment => if (c == '\n') {
                state = .code;
            },
            .block_comment => if (c == '*' and i + 1 < script.len and script[i + 1] == '/') {
                state = .code;
                i += 1;
            },
        }
    }

    // Trailing fragment without a `;`. Flush any word still open first so
    // a script ending in `END` closes its trigger body.
    if (word_start) |ws| classifyWord(script[ws..], &in_trigger, &trigger_depth);
    const tail = std.mem.trim(u8, script[start..], " \t\r\n");
    if (isMeaningful(tail)) {
        try out.append(allocator, .{
            .index = out.items.len,
            .text = tail,
            .offset = @intFromPtr(tail.ptr) - @intFromPtr(script.ptr),
        });
    }

    return out.toOwnedSlice(allocator);
}

/// Free the slice returned by `splitStatements`. The `text` fields are
/// borrowed from the script, so only the record array is freed.
pub fn freeStatements(allocator: Allocator, statements: []Statement) void {
    allocator.free(statements);
}

/// Feed one complete word to the trigger detector. Only `TRIGGER`, `BEGIN`
/// and `END` matter, and only once a `TRIGGER` has been seen — which is
/// what keeps a plain `BEGIN; ... COMMIT;` transaction splitting normally.
fn classifyWord(word: []const u8, in_trigger: *bool, trigger_depth: *i32) void {
    if (std.ascii.eqlIgnoreCase(word, "TRIGGER")) {
        in_trigger.* = true;
    } else if (in_trigger.*) {
        if (std.ascii.eqlIgnoreCase(word, "BEGIN")) {
            trigger_depth.* += 1;
        } else if (std.ascii.eqlIgnoreCase(word, "END") and trigger_depth.* > 0) {
            trigger_depth.* -= 1;
        }
    }
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Does this fragment contain anything other than whitespace and comments?
/// Used to drop `;;` and trailing `; -- done` noise.
pub fn isMeaningful(fragment: []const u8) bool {
    var i: usize = 0;
    while (i < fragment.len) {
        const c = fragment[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '-' and i + 1 < fragment.len and fragment[i + 1] == '-') {
            while (i < fragment.len and fragment[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < fragment.len and fragment[i + 1] == '*') {
            i += 2;
            while (i + 1 < fragment.len and !(fragment[i] == '*' and fragment[i + 1] == '/')) i += 1;
            i = @min(i + 2, fragment.len);
            continue;
        }
        return true;
    }
    return false;
}

/// Quote an identifier for interpolation into generated SQL.
///
/// The underlying binding binds every parameter as text and offers no
/// `sqlite3_bind_identifier`, so table and column names have to be
/// inlined. Anything interpolated this way MUST go through here, or a
/// table named `users; DROP TABLE users` becomes two statements.
pub fn quoteIdent(allocator: Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (name) |c| {
        if (c == '"') try out.append(allocator, '"');
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// True when `name` is a bare identifier that needs no quoting: a leading
/// letter or underscore, then letters/digits/underscores, non-empty, and
/// not a SQLite keyword that would change meaning if left bare.
pub fn isSimpleIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return !isReservedKeyword(name);
}

/// Quote only when necessary — keeps generated SQL readable in logs and
/// in the query pane, which matters because a DB app shows its SQL.
pub fn quoteIfNeeded(allocator: Allocator, name: []const u8) ![]u8 {
    if (isSimpleIdent(name)) return allocator.dupe(u8, name);
    return quoteIdent(allocator, name);
}

const reserved_keywords = [_][]const u8{
    "select",     "from",    "where",    "table",   "index",   "join",      "left",
    "right",      "inner",   "outer",    "group",   "order",   "having",    "limit",
    "offset",     "insert",  "update",   "delete",  "create",  "drop",      "alter",
    "and",        "or",      "not",      "null",    "on",      "as",        "by",
    "union",      "all",     "distinct", "case",    "when",    "then",      "else",
    "end",        "primary", "key",      "unique",  "default", "check",     "references",
    "constraint", "primary", "foreign",  "values",  "into",    "set",       "collate",
    "escape",     "pragma",  "vacuum",   "explain", "with",    "returning", "cast",
};

pub fn isReservedKeyword(word: []const u8) bool {
    for (reserved_keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(word, kw)) return true;
    }
    return false;
}

/// The leading keyword of a statement, uppercased. Skips leading
/// whitespace, line comments and block comments, and any opening
/// parens (so `(SELECT 1)` classifies as `SELECT`).
pub fn leadingKeyword(allocator: Allocator, sql: []const u8) ![]u8 {
    var i: usize = 0;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);
    while (i < sql.len) {
        const c = sql[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '(') {
            i += 1;
            continue;
        }
        if (c == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            while (i < sql.len and sql[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
            i = @min(i + 2, sql.len);
            continue;
        }
        break;
    }
    while (i < sql.len and isWordByte(sql[i])) : (i += 1) {
        try scratch.append(allocator, std.ascii.toUpper(sql[i]));
    }
    return scratch.toOwnedSlice(allocator);
}

/// Coarse classification of a statement, used to decide whether to run it
/// through the row-returning path or the fire-and-forget path.
pub const StatementKind = enum {
    select,
    with,
    explain,
    pragma,
    insert,
    update,
    delete,
    create,
    drop,
    alter,
    transaction,
    vacuum,
    replace,
    analyze,
    other,

    /// Does a successful run of this statement produce a result grid?
    ///
    /// `pragma` and `analyze` are answered per-subcommand: `PRAGMA
    /// journal_mode` returns a row, `PRAGMA journal_mode = WAL` does not.
    pub fn returnsRows(self: StatementKind, sql: []const u8) bool {
        return switch (self) {
            .select, .explain => true,
            .pragma, .analyze => !containsAssignment(sql),
            // A `WITH` is either a CTE-wrapped SELECT (rows) or a
            // CTE-wrapped DML (no rows). Scanning for the first top-level
            // data keyword after the CTE list is the pragmatic test.
            .with => withReturnsRows(sql),
            else => false,
        };
    }

    /// Is this statement a mutation the user should be able to undo by
    /// re-running it in a transaction? Drives the CLI's confirmation
    /// prompt.
    pub fn isMutation(self: StatementKind) bool {
        return switch (self) {
            .insert, .update, .delete, .drop, .alter, .replace => true,
            else => false,
        };
    }
};

/// A bare `PRAGMA foo` reads; `PRAGMA foo = bar` writes. Distinguish by
/// looking for an `=` outside of quotes before any parenthesised argument.
fn containsAssignment(sql: []const u8) bool {
    var state: State = .code;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        switch (state) {
            .code => switch (c) {
                '\'' => state = .single_quote,
                '"' => state = .double_quote,
                '`' => state = .backtick_quote,
                '[' => state = .bracket_quote,
                '-' => if (i + 1 < sql.len and sql[i + 1] == '-') {
                    state = .line_comment;
                    i += 1;
                },
                '/' => if (i + 1 < sql.len and sql[i + 1] == '*') {
                    state = .block_comment;
                    i += 1;
                },
                '=' => {
                    return true;
                },
                else => {},
            },
            .single_quote => {
                if (c == '\'') {
                    if (i + 1 < sql.len and sql[i + 1] == '\'') i += 1 else state = .code;
                }
            },
            .double_quote => {
                if (c == '"') {
                    if (i + 1 < sql.len and sql[i + 1] == '"') i += 1 else state = .code;
                }
            },
            .backtick_quote => {
                if (c == '`') state = .code;
            },
            .bracket_quote => {
                if (c == ']') state = .code;
            },
            .line_comment => {
                if (c == '\n') state = .code;
            },
            .block_comment => {
                if (c == '*' and i + 1 < sql.len and sql[i + 1] == '/') {
                    state = .code;
                    i += 1;
                }
            },
        }
    }
    return false;
}

/// `WITH x AS (...) SELECT ...` returns rows; `WITH x AS (...) INSERT ...`
/// does not.
///
/// The decision hinges on the keyword that follows the *last* CTE body, so
/// this scans forward while tracking paren depth and ignores everything
/// until the closing `)` of the CTE list brings the depth back to zero.
fn withReturnsRows(sql: []const u8) bool {
    var depth: i32 = 0;
    var state: State = .code;
    // Set once we have seen at least one complete `AS (...)` body. Until
    // then, keywords belong to the CTE list, not to the real statement.
    var seen_body = false;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        switch (state) {
            .code => {
                switch (c) {
                    '\'' => state = .single_quote,
                    '"' => state = .double_quote,
                    '`' => state = .backtick_quote,
                    '[' => state = .bracket_quote,
                    '-' => {
                        if (i + 1 < sql.len and sql[i + 1] == '-') {
                            state = .line_comment;
                            i += 1;
                        }
                    },
                    '/' => {
                        if (i + 1 < sql.len and sql[i + 1] == '*') {
                            state = .block_comment;
                            i += 1;
                        }
                    },
                    ')', '(', ' ' => {
                        // `)` closes a CTE body; `(` opens a nested one (any
                        // earlier `seen_body` is then stale); whitespace is
                        // not a decision point.
                        if (c == '(') {
                            seen_body = false;
                            depth += 1;
                        } else if (c == ')') {
                            depth -= 1;
                            if (depth <= 0) seen_body = true;
                        }
                    },
                    '\t', '\r', '\n' => {},
                    // A comma after a completed CTE means another CTE
                    // follows (`WITH a AS (...), b AS (...) SELECT ...`).
                    // The next word will be that CTE's NAME, not the real
                    // statement keyword, so keep waiting.
                    ',' => {
                        seen_body = false;
                    },
                    else => {
                        // A real word at depth 0 after the CTE list.
                        if (seen_body and depth == 0) {
                            return std.ascii.startsWithIgnoreCase(sql[i..], "select");
                        }
                        // Still inside the CTE list: not the statement yet.
                    },
                }
            },
            .single_quote => {
                if (c == '\'') {
                    if (i + 1 < sql.len and sql[i + 1] == '\'') i += 1 else state = .code;
                }
            },
            .double_quote => {
                if (c == '"') {
                    if (i + 1 < sql.len and sql[i + 1] == '"') i += 1 else state = .code;
                }
            },
            .backtick_quote => {
                if (c == '`') state = .code;
            },
            .line_comment => {
                if (c == '\n') state = .code;
            },
            .block_comment => {
                if (c == '*' and i + 1 < sql.len and sql[i + 1] == '/') {
                    state = .code;
                    i += 1;
                }
            },
            .bracket_quote => {
                if (c == ']') state = .code;
            },
        }
    }
    return false;
}

pub fn classify(allocator: Allocator, sql: []const u8) !StatementKind {
    const kw = try leadingKeyword(allocator, sql);
    defer allocator.free(kw);
    if (eqlKw(kw, "SELECT")) return .select;
    if (eqlKw(kw, "VALUES")) return .select;
    if (eqlKw(kw, "WITH")) return .with;
    if (eqlKw(kw, "EXPLAIN")) return .explain;
    if (eqlKw(kw, "PRAGMA")) return .pragma;
    if (eqlKw(kw, "INSERT")) return .insert;
    if (eqlKw(kw, "REPLACE")) return .replace;
    if (eqlKw(kw, "UPDATE")) return .update;
    if (eqlKw(kw, "DELETE")) return .delete;
    if (eqlKw(kw, "CREATE")) return .create;
    if (eqlKw(kw, "DROP")) return .drop;
    if (eqlKw(kw, "ALTER")) return .alter;
    if (eqlKw(kw, "BEGIN") or eqlKw(kw, "COMMIT") or eqlKw(kw, "ROLLBACK") or
        eqlKw(kw, "END") or eqlKw(kw, "SAVEPOINT") or eqlKw(kw, "RELEASE")) return .transaction;
    if (eqlKw(kw, "VACUUM")) return .vacuum;
    if (eqlKw(kw, "ANALYZE")) return .analyze;
    return .other;
}

fn eqlKw(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "split: single statement, no trailing semicolon" {
    const stmts = try splitStatements(testing.allocator, "SELECT 1");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqualStrings("SELECT 1", stmts[0].text);
}

test "split: two statements" {
    const stmts = try splitStatements(testing.allocator, "SELECT 1; SELECT 2");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("SELECT 1", stmts[0].text);
    try testing.expectEqualStrings("SELECT 2", stmts[1].text);
}

test "split: drops empty statements" {
    const stmts = try splitStatements(testing.allocator, ";;SELECT 1;;;SELECT 2;;");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("SELECT 1", stmts[0].text);
    try testing.expectEqualStrings("SELECT 2", stmts[1].text);
}

test "split: semicolon inside a string literal is not a terminator" {
    const stmts = try splitStatements(testing.allocator, "SELECT 'a;b' FROM t; SELECT 2");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("SELECT 'a;b' FROM t", stmts[0].text);
    try testing.expectEqualStrings("SELECT 2", stmts[1].text);
}

test "split: doubled quote inside a literal does not end it" {
    const stmts = try splitStatements(testing.allocator, "SELECT 'it''s; fine'; SELECT 2");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("SELECT 'it''s; fine'", stmts[0].text);
}

test "split: semicolon inside a quoted identifier" {
    const stmts = try splitStatements(testing.allocator, "SELECT \"a;b\" FROM t; SELECT 2");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("SELECT \"a;b\" FROM t", stmts[0].text);
}

test "split: semicolon inside line and block comments" {
    const stmts = try splitStatements(testing.allocator, "SELECT 1 -- ; nope\n; /* ; nope */ SELECT 2");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("SELECT 1 -- ; nope", stmts[0].text);
    try testing.expectEqualStrings("/* ; nope */ SELECT 2", stmts[1].text);
}

test "split: comment-only fragments are dropped" {
    const stmts = try splitStatements(testing.allocator, "SELECT 1; -- just a comment\n; /* block */ ; SELECT 2");
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
}

test "split: trigger body keeps its internal semicolons" {
    const script =
        \\CREATE TRIGGER t AFTER INSERT ON a BEGIN
        \\  UPDATE b SET n = 1;
        \\  DELETE FROM c;
        \\END;
        \\SELECT 1
    ;
    const stmts = try splitStatements(testing.allocator, script);
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expect(std.mem.indexOf(u8, stmts[0].text, "UPDATE b SET n = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, stmts[0].text, "DELETE FROM c;") != null);
    try testing.expectEqualStrings("SELECT 1", stmts[1].text);
}

test "split: statement offsets point at the right bytes" {
    const script = "SELECT 1;\n  SELECT 2;";
    const stmts = try splitStatements(testing.allocator, script);
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqualStrings("SELECT 1", script[stmts[0].offset..][0..stmts[0].text.len]);
    try testing.expectEqualStrings("SELECT 2", script[stmts[1].offset..][0..stmts[1].text.len]);
}

test "quoteIdent: doubles embedded quotes" {
    const q = try quoteIdent(testing.allocator, "we\"ird");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("\"we\"\"ird\"", q);
}

test "quoteIdent: neutralises a statement-injection attempt" {
    const q = try quoteIdent(testing.allocator, "users; DROP TABLE users; --");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("\"users; DROP TABLE users; --\"", q);
    // And the result is a single statement when run through the splitter.
    const sql = try std.fmt.allocPrint(testing.allocator, "SELECT * FROM {s}", .{q});
    defer testing.allocator.free(sql);
    const stmts = try splitStatements(testing.allocator, sql);
    defer freeStatements(testing.allocator, stmts);
    try testing.expectEqual(@as(usize, 1), stmts.len);
}

test "isSimpleIdent" {
    try testing.expect(isSimpleIdent("users"));
    try testing.expect(isSimpleIdent("_x1"));
    try testing.expect(!isSimpleIdent(""));
    try testing.expect(!isSimpleIdent("1abc"));
    try testing.expect(!isSimpleIdent("has space"));
    try testing.expect(!isSimpleIdent("select"));
    try testing.expect(!isSimpleIdent("user-name"));
}

test "quoteIfNeeded leaves plain names alone" {
    const a = try quoteIfNeeded(testing.allocator, "users");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("users", a);

    const b = try quoteIfNeeded(testing.allocator, "my table");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("\"my table\"", b);
}

test "leadingKeyword skips comments and parens, uppercases" {
    const k1 = try leadingKeyword(testing.allocator, "  -- c\n (select 1)");
    defer testing.allocator.free(k1);
    try testing.expectEqualStrings("SELECT", k1);

    const k2 = try leadingKeyword(testing.allocator, "/* c */ update t set a=1");
    defer testing.allocator.free(k2);
    try testing.expectEqualStrings("UPDATE", k2);
}

test "classify maps every leading keyword" {
    const cases = [_]struct { []const u8, StatementKind }{
        .{ "SELECT 1", .select },
        .{ "VALUES (1)", .select },
        .{ "WITH a AS (SELECT 1) SELECT * FROM a", .with },
        .{ "EXPLAIN SELECT 1", .explain },
        .{ "PRAGMA table_info(t)", .pragma },
        .{ "INSERT INTO t VALUES (1)", .insert },
        .{ "UPDATE t SET a=1", .update },
        .{ "DELETE FROM t", .delete },
        .{ "CREATE TABLE t (a)", .create },
        .{ "DROP TABLE t", .drop },
        .{ "ALTER TABLE t RENAME TO u", .alter },
        .{ "BEGIN", .transaction },
        .{ "COMMIT", .transaction },
        .{ "ROLLBACK", .transaction },
        .{ "VACUUM", .vacuum },
        .{ "ANALYZE", .analyze },
        .{ "REPLACE INTO t VALUES (1)", .replace },
        .{ "EXPLAINING", .other },
    };
    for (cases) |c| {
        const got = try classify(testing.allocator, c[0]);
        try testing.expectEqual(c[1], got);
    }
}

test "returnsRows distinguishes reading PRAGMA from writing it" {
    try testing.expect((try classify(testing.allocator, "PRAGMA journal_mode")).returnsRows("PRAGMA journal_mode"));
    try testing.expect(!(try classify(testing.allocator, "PRAGMA journal_mode = WAL")).returnsRows("PRAGMA journal_mode = WAL"));
    // A quoted `=` must not count as an assignment.
    try testing.expect((try classify(testing.allocator, "PRAGMA table_info('a=b')")).returnsRows("PRAGMA table_info('a=b')"));
}

test "returnsRows for WITH follows the wrapped statement" {
    const sel = "WITH a AS (SELECT 1) SELECT * FROM a";
    try testing.expect((try classify(testing.allocator, sel)).returnsRows(sel));
    const ins = "WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a";
    try testing.expect(!(try classify(testing.allocator, ins)).returnsRows(ins));
    // Multiple CTEs: the keyword after the LAST body is what counts.
    const multi = "WITH a AS (SELECT 1), b AS (SELECT 2) SELECT * FROM b";
    try testing.expect((try classify(testing.allocator, multi)).returnsRows(multi));
    // A CTE body containing the word SELECT must not fool the scanner.
    const tricky = "WITH a AS (SELECT x FROM t) DELETE FROM t";
    try testing.expect(!(try classify(testing.allocator, tricky)).returnsRows(tricky));
}

test "isMutation" {
    try testing.expect((try classify(testing.allocator, "DROP TABLE t")).isMutation());
    try testing.expect(!(try classify(testing.allocator, "SELECT 1")).isMutation());
}
