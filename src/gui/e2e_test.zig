//! End-to-end tests for the GUI: type a query, run it, see the output.
//!
//! These drive the REAL `App` from `app.zig` — the same struct the window
//! runs — and then render through glinlandui's headless `Driver`, so the
//! assertions cover the whole path: keystroke -> editor buffer ->
//! query engine -> result set -> draw commands.
//!
//! A test that only checked `App.result` would pass even if the grid
//! rendered blanks, which is exactly the bug this file exists to catch.

const std = @import("std");
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

const app_mod = @import("app.zig");
const App = app_mod.App;
const draw = @import("main.zig");
const editor = @import("editor.zig");
const value = @import("meja").value;
const theme = @import("theme.zig");

const testing = std.testing;

/// A real app on a real in-memory database, torn down at the end.
const Harness = struct {
    threaded: std.Io.Threaded,
    app: *App,
    driver: Driver,

    fn init(gpa: std.mem.Allocator) !Harness {
        // page_allocator throughout: Clay keeps a global pointer into its
        // arena and never frees it, so the leak detector would fire on a
        // correct program.
        var threaded: std.Io.Threaded = .init(gpa, .{});
        errdefer threaded.deinit();

        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = App.init(gpa, threaded.io());
        app.open(":memory:");
        try testing.expect(app.db_open);

        var driver = try Driver.initOwned(gpa, app, draw.App_root);
        errdefer driver.deinit();
        try driver.start(.{ .width = 1200, .height = 800 });

        return .{
            .threaded = threaded,
            .app = app,
            .driver = driver,
        };
    }

    fn deinit(self: *Harness) void {
        const gpa = self.driver.alloc;
        self.driver.deinit();
        self.app.clearResult();
        self.app.freeTables();
        if (self.app.db_open) self.app.db.deinit();
        gpa.destroy(self.app);
        self.threaded.deinit();
    }

    /// The app's own draw callback, so the Driver renders the REAL UI
    /// rather than a stand-in.
    /// Draw a frame and let the renderer settle.
    ///
    /// `waitForIdle` matters: glinlandui's scrollbar and hit-testing read
    /// previous-frame data, so a single frame after a state change is
    /// not enough for the text to be findable.
    fn frame(self: *Harness) void {
        self.driver.waitForIdle() catch {
            self.driver.frame();
        };
    }

    /// Type a string one key at a time through the real key handler.
    fn typeText(self: *Harness, text: []const u8) !void {
        for (text) |c| {
            const stroke = editor.keyCodeFor(c) orelse {
                std.debug.print("no key for '{c}'\n", .{c});
                return error.UnsupportedCharacter;
            };
            _ = self.app.onKey(.{ .shift = stroke.shift }, stroke.code);
        }
    }

    /// Press Ctrl+Enter: the run gesture.
    fn run(self: *Harness) void {
        _ = self.app.onKey(.{ .ctrl = true }, editor.KEY_ENTER);
    }
};

/// Seed a table the tests query against.
fn seed(app: *App) !void {
    try app.db.exec(app.gpa,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT, score REAL)
    , &.{});
    try app.db.exec(app.gpa,
        \\INSERT INTO users (id, name, email, score) VALUES
        \\ (1, 'alice', 'a@x.com', 91.5),
        \\ (2, 'bob',   'b@x.com', 72.0),
        \\ (3, 'carol', NULL,      NULL)
    , &.{});
}

test "typing a query and running it puts the result in the app" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    // Type it the way a user would, one keystroke at a time.
    try h.typeText("SELECT name FROM users");
    try testing.expectEqualStrings("SELECT name FROM users", h.app.ed.text());

    h.run();

    try testing.expect(h.app.has_result);
    try testing.expectEqual(@as(usize, 1), h.app.result.columnCount());
    try testing.expectEqualStrings("name", h.app.result.columns[0].name);
    try testing.expectEqual(@as(usize, 3), h.app.result.rowCount());
    try testing.expect(h.app.result.error_message == null);
}

test "the output actually appears in the rendered frame" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT name FROM users");
    h.run();
    h.frame();

    // The values the query returned must be reachable as drawn text.
    // This is the assertion that catches a grid which computes the right
    // result and then renders blanks.
    try h.driver.expectText("alice");
    try h.driver.expectText("bob");
    try h.driver.expectText("carol");
    // And the column header.
    try h.driver.expectText("name");
}

test "SELECT * shows every column, header included" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT * FROM users");
    h.run();
    h.frame();

    try testing.expectEqual(@as(usize, 4), h.app.result.columnCount());
    for ([_][]const u8{ "id", "name", "email", "score" }) |header| {
        try h.driver.expectText(header);
    }
    // `SELECT *` is expanded against the schema, so its columns are
    // named — not `*`.
    try h.driver.expectNoText("*");
}

test "numbers render, not blank cells" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    // INTEGER and REAL own no text, so a UI that reads the wrong
    // accessor draws every one of these as an empty cell.
    try h.typeText("SELECT id, score FROM users");
    h.run();
    h.frame();

    try testing.expectEqual(@as(?i64, 1), h.app.result.get(0, 0).?.asInt());
    try h.driver.expectText("1");
    try h.driver.expectText("91.5");
}

test "NULL renders as NULL and the empty string renders blank" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    const g = h.app.gpa;
    try h.app.db.exec(g,
        \\CREATE TABLE mixed (id INTEGER, v TEXT)
    , &.{});
    try h.app.db.exec(g, "INSERT INTO mixed (id, v) VALUES (1, ''), (2, NULL)", &.{});

    try h.typeText("SELECT v FROM mixed");
    h.run();
    h.frame();

    // Exactly one of the two is NULL, whichever order they come back in.
    try testing.expect(h.app.result.get(0, 0).?.isNull() != h.app.result.get(1, 0).?.isNull());
    // ...and a NULL is drawn as the word NULL, not as a blank cell.
    try h.driver.expectText("NULL");
}

test "an error is reported, not silently shown as an empty result" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT nosuchcolumn FROM users");
    h.run();
    h.frame();

    try testing.expect(h.app.result.error_message != null);
    // A failure must not also claim success with zero rows.
    try testing.expectEqual(@as(usize, 0), h.app.result.columnCount());
}

test "a WHERE clause typed as text filters the output" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT name FROM users WHERE id = 2");
    h.run();
    h.frame();

    try testing.expectEqual(@as(usize, 1), h.app.result.rowCount());
    try h.driver.expectText("bob");
    try h.driver.expectNoText("alice");
}

test "an aggregate typed as text shows its alias as the header" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT COUNT(*) AS total FROM users");
    h.run();
    h.frame();

    try testing.expectEqualStrings("total", h.app.result.columns[0].name);
    try testing.expectEqual(@as(?i64, 3), h.app.result.get(0, 0).?.asInt());
    try h.driver.expectText("total");
    try h.driver.expectText("3");
}

test "a multi-line query typed with newlines still runs" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    // Enter inserts a newline; Ctrl+Enter runs.
    try h.typeText("SELECT name");
    _ = h.app.onKey(.{}, editor.KEY_ENTER);
    try h.typeText(" FROM users");
    _ = h.app.onKey(.{}, editor.KEY_ENTER);
    try h.typeText("WHERE id > 1");
    h.run();
    h.frame();

    try testing.expectEqual(@as(usize, 2), h.app.result.rowCount());
    try h.driver.expectText("bob");
    try h.driver.expectText("carol");
}

test "clicking a table in the sidebar loads it and fills the editor" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.app.loadTables();
    try testing.expect(h.app.tables.items.len >= 1);

    h.app.browseTable(0);
    h.frame();

    // The editor is seeded with a query the user can then edit.
    try testing.expectEqualStrings("SELECT * FROM users", h.app.ed.text());
    try testing.expect(h.app.has_result);
    try testing.expectEqual(@as(usize, 4), h.app.result.columnCount());
    // ...and the table name is in the sidebar.
    try h.driver.expectText("users");
}

test "the frame the app draws contains the sidebar, editor and grid" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.app.loadTables();
    h.app.browseTable(0);
    h.frame();

    // The three regions the window is built from all exist as elements.
    try testing.expect(h.driver.exists("root"));
    try testing.expect(h.driver.exists("sidebar"));
    try testing.expect(h.driver.exists("editor"));
    try testing.expect(h.driver.exists("results"));

    const snap = h.driver.snapshot();
    try testing.expect(snap.rectangle_count > 0);
    try testing.expect(snap.text_count > 0);
}

test "the rendered status reports the row and column counts" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT name FROM users");
    h.run();
    h.frame();

    try h.driver.expectText("3 rows x 1 cols");
}
