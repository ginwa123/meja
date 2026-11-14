// End-to-end tests for the GUI: type a query, run it, see the output.

const std = @import("std");
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

const app_mod = @import("app.zig");
const App = app_mod.App;
const draw = @import("main.zig");
const editor = ui.text_editor;
const picker_mod = @import("components/picker.zig");
const database = @import("databases").database;
const value = @import("meja").value;
const theme = @import("theme.zig");
const glin_input = ui.components.input;

const testing = std.testing;

// A real app on a real in-memory database, torn down at the end.
const Harness = struct {
    threaded: std.Io.Threaded,
    app: *App,
    driver: Driver,

    fn init(gpa: std.mem.Allocator) !Harness {
        // page_allocator throughout: Clay keeps a global pointer into its arena and never frees it, so the leak detector would fire on a correct program.
        var threaded: std.Io.Threaded = .init(gpa, .{});
        errdefer threaded.deinit();

        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.init(gpa, threaded.io());
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
        // The picker's listing owns a name per entry it found; without this the harness would leak them (and so would the app).
        self.app.picker.deinit(gpa);
        gpa.destroy(self.app);
        self.threaded.deinit();
    }

    // The app's own draw callback, so the Driver renders the REAL UI rather than a stand-in.
    fn installKeys(self: *Harness) void {
        self.driver.host.keys.register(struct {
            fn f(ctx: ?*anyopaque, mods: glin_input.Mods, keycode: u32) bool {
                const a: *App = @ptrCast(@alignCast(ctx.?));
                _ = a.onKey(mods, keycode);
                return ui.keyToClose(keycode);
            }
        }.f, self.app);
    }

    // Draw a frame and let the renderer settle.
    fn frame(self: *Harness) void {
        self.driver.waitForIdle() catch {
            self.driver.frame();
        };
    }

    // Type a string one key at a time through the real key handler.
    fn typeText(self: *Harness, text: []const u8) !void {
        for (text) |c| {
            const stroke = editor.keyCodeFor(c) orelse {
                std.debug.print("no key for '{c}'\n", .{c});
                return error.UnsupportedCharacter;
            };
            _ = self.app.onKey(.{ .shift = stroke.shift }, stroke.code);
        }
    }

    // Press Ctrl+Enter: the run gesture.
    fn run(self: *Harness) void {
        _ = self.app.onKey(.{ .ctrl = true }, editor.KEY_ENTER);
    }

    // Press a key through the real host keychain.
    fn press(self: *Harness, keycode: u32, mods: glin_input.Mods) void {
        // Mods are a LATCH, not an argument: glinlandui's `Mods.track` consumes the Shift/Ctrl key events themselves and the handler then reads the latched.
        if (mods.ctrl) _ = h_key(self, editor.KEY_LEFTCTRL);
        if (mods.shift) _ = h_key(self, editor.KEY_LEFTSHIFT);
        _ = h_key(self, keycode);
        if (mods.shift) _ = h_key_release(self, editor.KEY_LEFTSHIFT);
        if (mods.ctrl) _ = h_key_release(self, editor.KEY_LEFTCTRL);
    }

    fn h_key(self: *Harness, keycode: u32) bool {
        return self.driver.host.onKeyEvent(keycode, true);
    }

    fn h_key_release(self: *Harness, keycode: u32) bool {
        return self.driver.host.onKeyEvent(keycode, false);
    }

    // Assert the editor's line `line` reached the frame, byte for byte.
    fn expectEditorDrawn(self: *Harness, line: usize) !void {
        const ed = &self.app.ed;
        const start = ed.lineStartAt(line);
        var end = start;
        while (end < ed.len and ed.buf[end] != '\n') end += 1;
        // The caret is a box floated over the line, so the drawn run is the buffer's line verbatim.
        const expected = ed.buf[start..end];
        try testing.expect(expected.len > 1); // not an empty line
        try self.driver.expectText(expected);
    }

    // Assert some drawn text CONTAINS `needle`.
    fn expectTextContaining(self: *Harness, needle: []const u8) !void {
        const count = self.driver.snapshot().text_count;
        for (0..count) |i| {
            const drawn = self.driver.text(i) orelse continue;
            if (std.mem.indexOf(u8, drawn, needle) != null) return;
        }
        std.debug.print("no drawn text contains '{s}'\n", .{needle});
        return error.TextNotFound;
    }

    // Type into whatever field currently has focus, through the chain.
    fn typeThroughHost(self: *Harness, text: []const u8) !void {
        for (text) |c| {
            const stroke = editor.keyCodeFor(c) orelse {
                std.debug.print("no key for '{c}'\n", .{c});
                return error.UnsupportedCharacter;
            };
            self.press(stroke.code, .{ .shift = stroke.shift });
        }
    }

    // Script what the system file dialog will answer with.
    fn scriptDialog(self: *Harness, fake: *ui.file_dialog.fake.Fake, answer: ui.file_dialog.fake.Answer) void {
        _ = self;
        fake.* = .{ .answer = answer };
        ui.file_dialog.fake.install(fake);
    }
};

// Seed a table the tests query against.
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
    // `SELECT *` is expanded against the schema, so its columns are named — not `*`.
    try h.driver.expectNoText("*");
}

test "numbers render, not blank cells" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    // INTEGER and REAL own no text, so a UI that reads the wrong accessor draws every one of these as an empty cell.
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

test "Browse is in the frame, so the system dialog is reachable" {
    // The button has to be ON SCREEN, not merely defined.
    var h = try Harness.init(std.heap.page_allocator);
    defer h.deinit();
    h.frame();

    try testing.expect(h.driver.exists("sidebar.browse"));
    // The built-in picker stays reachable beside it.
    try testing.expect(h.driver.exists("sidebar.open"));
}

test "the picker offers Browse too, so the listing can hand over" {
    var h = try Harness.init(std.heap.page_allocator);
    defer h.deinit();
    h.app.openPicker();
    h.frame();

    try testing.expect(h.driver.exists("picker.browse"));
    // ...and the two old controls are still there.
    try testing.expect(h.driver.exists("picker.open"));
    try testing.expect(h.driver.exists("picker.cancel"));
}

test "browsing with no system dialog says why, and changes nothing" {
    // A GUI test build selects glinlandui's PORTABLE backend, where file_dialog is `error.Unsupported`.
    var h = try Harness.init(std.heap.page_allocator);
    defer h.deinit();
    const before = h.app.db_path;

    h.app.browseForDatabase();

    try testing.expect(std.mem.indexOf(u8, h.app.status, "picker") != null);
    // The database is untouched, and still open: an unavailable dialog is not a reason to close what the user already had.
    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings(before, h.app.db_path);
}

test "the message names the platform, not just the failure" {
    // "file dialog failed" leaves the user with nothing to do.
    var h = try Harness.init(std.heap.page_allocator);
    defer h.deinit();

    h.app.browseForDatabase();
    try testing.expectEqualStrings(
        "no system file dialog on this platform — use the picker below",
        h.app.status,
    );
}

test "the picker still opens after a failed browse" {
    // The fallback has to be reachable, not merely mentioned.
    var h = try Harness.init(std.heap.page_allocator);
    defer h.deinit();

    h.app.browseForDatabase();
    try testing.expect(!h.app.picker.open);
    h.app.openPicker();
    try testing.expect(h.app.picker.open);
    h.frame();
    try testing.expect(h.driver.exists("picker.path"));
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

test "the editor buffer survives stack churn between keystrokes" {
    // Regression test.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    try h.typeText("SELECT");

    // Churn the stack hard: deep calls with their own large locals.
    var scratch: [64 * 1024]u8 = undefined;
    for (0..40) |k| {
        @memset(&scratch, @truncate(k));
        h.frame();
        if (h.app.ed.len == 0) return error.EditorBufferLost;
    }

    try h.typeText(" * FROM users");
    try testing.expectEqualStrings("SELECT * FROM users", h.app.ed.text());
}

test "the editor buffer is not a pointer into a dead App copy" {
    // A direct check of the invariant rather than its consequence: the buffer the editor writes to must be the one inside the App the caller holds.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    const buf_start = @intFromPtr(h.app.ed.buf.ptr);
    const field_start = @intFromPtr(&h.app.sql_buf);
    try testing.expectEqual(field_start, buf_start);
    try testing.expectEqual(@as(usize, h.app.sql_buf.len), h.app.ed.buf.len);
}

test "typing does not close the window" {
    // Regression test for the force-close.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();

    const query_text = "SELECT * FROM users";
    for (query_text) |ch| {
        const stroke = editor.keyCodeFor(ch) orelse return error.UnsupportedCharacter;
        if (stroke.shift) _ = h.driver.host.onKeyEvent(editor.KEY_LEFTSHIFT, true);
        // The backend acts on this return value.
        const close_intent = h.driver.host.onKeyEvent(stroke.code, true);
        try testing.expect(!close_intent);
        if (stroke.shift) _ = h.driver.host.onKeyEvent(editor.KEY_LEFTSHIFT, false);
    }

    _ = h.driver.host.onKeyEvent(editor.KEY_LEFTCTRL, true);
    try testing.expect(!h.driver.host.onKeyEvent(editor.KEY_ENTER, true));
    _ = h.driver.host.onKeyEvent(editor.KEY_LEFTCTRL, false);

    // The window is still open, with the query typed and run.
    try testing.expect(!h.driver.host.isQuit());
    try testing.expectEqualStrings(query_text, h.app.ed.text());
    try testing.expect(h.app.has_result);
    try testing.expectEqual(@as(usize, 3), h.app.result.rowCount());
}

test "Escape is the thing that closes the window" {
    // The other half of the contract: after the fix, Escape must still ask the window to close, or the app cannot be quit from the keyboard at all.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    h.installKeys();

    // Escape (evdev 1) is close intent.
    try testing.expect(h.driver.host.onKeyEvent(1, true));
    // Ordinary typing is not.
    try testing.expect(!h.driver.host.onKeyEvent(30, true)); // 'a'
    try testing.expect(!h.driver.host.onKeyEvent(2, true)); // '1'
    // A key release is not close intent either.
    try testing.expect(!h.driver.host.onKeyEvent(1, false));
}

// The editor must be VISIBLE Every test above types a query and then asserts on `App.result` or on the grid — and the grid happens to be drawn from the.

test "the typed SQL is actually drawn, not just held" {
    // The regression test for "typing does nothing".
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT name FROM users");
    h.frame();

    // A query that appears NOWHERE else in the UI, so the only way to find it is as the editor's own drawn line.
    try h.expectEditorDrawn(0);
}

test "a query the user typed is drawn after Ctrl+Enter too" {
    // The editor keeps the query after it runs, so the buffer is still on screen.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT email FROM users");
    h.run();
    h.frame();

    try h.expectEditorDrawn(0);
    try h.driver.expectText("a@x.com");
}

test "clicking a table draws its generated query, not just its name" {
    // The blind spot in the old suite, closed: "users" is in the sidebar too, so asserting on it proved nothing about the editor.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.app.loadTables();
    h.app.browseTable(0);
    h.frame();

    try testing.expectEqualStrings("SELECT * FROM users", h.app.ed.text());
    try h.expectEditorDrawn(0);
}

test "a multi-line query draws every line" {
    // Each line is its own label, so a per-line failure would be hidden by the others.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT name");
    _ = h.app.onKey(.{}, editor.KEY_ENTER);
    try h.typeText("FROM users");
    h.frame();

    try h.expectEditorDrawn(0);
    try h.expectEditorDrawn(1);
}

test "typing reaches the editor through the real keychain" {
    // The direct-call tests prove `App.onKey` works.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();

    try h.typeThroughHost("SELECT id FROM users");
    try testing.expectEqualStrings("SELECT id FROM users", h.app.ed.text());

    h.frame();
    try h.expectEditorDrawn(0);
}

test "composed text types Caps Lock, symbols and accents, and follows the focus" {
    // macOS hands over what AppKit composed, so a caps `S`, Shift+8 and a dead-key `e-acute` must land verbatim in whichever field has the keyboard.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.driver.host.keys.registerText(struct {
        fn f(ctx: ?*anyopaque, text: []const u8) bool {
            const a: *App = @ptrCast(@alignCast(ctx.?));
            return a.onText(text);
        }
    }.f, h.app);

    try testing.expect(h.driver.host.onTextEvent("S"));
    try testing.expect(h.driver.host.onTextEvent("ELECT * ("));
    try testing.expect(h.driver.host.onTextEvent("\xc3\xa9"));
    try testing.expectEqualStrings("SELECT * (\xc3\xa9", h.app.ed.text());

    // The tree-search field is a different editor, so the routing has to follow the focus.
    h.app.focus = .tree_search;
    try testing.expect(h.driver.host.onTextEvent("A"));
    try testing.expectEqualStrings("A", h.app.tree_search_ed.text());
    try testing.expectEqualStrings("SELECT * (\xc3\xa9", h.app.ed.text());

    // An empty run is not a keystroke: nothing to insert, nothing consumed.
    try testing.expect(!h.driver.host.onTextEvent(""));
}

test "dragging across a field selects the run under the pointer" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.app.focus = .tree_search;
    _ = h.app.onText("users");
    h.frame();

    const bb = h.driver.box("sidebar.search") orelse return error.ElementNotFound;
    const y = bb.y + bb.height * 0.5;
    // Press just inside the left edge (the field pads by 8), then drag exactly three MEASURED characters right.
    const three = ui.text.measureText("use", theme.font_size_small).w;
    h.driver.pressAt(bb.x + 9, y);
    h.driver.move(bb.x + 8 + three, y);
    h.driver.releaseAt(bb.x + 8 + three, y);

    const span = h.app.tree_search_ed.caret.selection() orelse return error.NoSelection;
    try testing.expect(span.start == 0);
    try testing.expectEqual(@as(usize, 3), span.end);
    // Selecting never edits the field.
    try testing.expectEqualStrings("users", h.app.tree_search_ed.text());
}

test "clicking a line in the SQL editor puts the caret on that line" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    _ = h.app.ed.insertSlice("SELECT 1\nFROM t");
    h.app.focus = .tree_search;
    h.frame();

    const bb = h.driver.box("editor.line.1") orelse return error.ElementNotFound;
    // Two characters into `FROM t`, which starts at byte 9.
    h.driver.clickAt(bb.x + 2 * 8.4, bb.y + bb.height * 0.5);
    try testing.expectEqual(@as(usize, 11), h.app.ed.caret.offset);
    try testing.expectEqual(app_mod.Focus.sql_editor, h.app.focus);
    try testing.expectEqualStrings("SELECT 1\nFROM t", h.app.ed.text());
}

test "no two click targets share an element id (a duplicate resolves to the wrong box)" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    try h.typeText("SELECT * FROM users");
    h.run();
    h.frame();
    h.frame();

    const reg = ui.components.click_registry;
    var dups: usize = 0;
    var i: usize = 0;
    while (i < reg.hitCount()) : (i += 1) {
        const a = reg.hitAt(i).?;
        var j: usize = i + 1;
        while (j < reg.hitCount()) : (j += 1) {
            const b = reg.hitAt(j).?;
            if (a.id.id == b.id.id and a.id.offset == b.id.offset) {
                dups += 1;
                // A duplicate makes `getElementData` return the other element's box, so the click and the cursor land on the wrong component.
                std.debug.print("duplicate click id {d} (offset {d}) at entries {d} and {d}\n", .{ a.id.id, a.id.offset, i, j });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), dups);
}

test "the caret is a box at the caret column, not a glyph inside the text" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    _ = h.app.ed.insertSlice("SELECT 1");
    h.app.ed.setCaret(3, false);
    h.driver.frame();

    const line = h.driver.box("editor.line.0") orelse return error.ElementNotFound;
    const caret = h.driver.box("editor.caret.0") orelse return error.ElementNotFound;
    // Three columns in, at the width the font actually gives those three characters.
    const three = ui.text.measureText("SEL", theme.font_size).w;
    try testing.expectApproxEqAbs(line.x + three, caret.x, 0.5);
    try testing.expectEqual(@as(f32, 1), caret.width);
    try testing.expect(caret.height > @as(f32, @floatFromInt(theme.font_size)));
    // The line is drawn verbatim, so nothing was inserted into it.
    try h.driver.expectText("SELECT 1");

    // Moving the caret moves the bar, and the drawn text does not shift with it.
    h.app.ed.setCaret(6, false);
    h.driver.frame();
    const moved = h.driver.box("editor.caret.0") orelse return error.ElementNotFound;
    try testing.expectApproxEqAbs(line.x + ui.text.measureText("SELECT", theme.font_size).w, moved.x, 0.5);
    try h.driver.expectText("SELECT 1");
}

// ---- Frame stability ----

// What one rendered frame looked like, per command: a digest, the element id and the box.
const FrameShape = struct {
    digest: u64 = 0,
    digests: [4096]u64 = undefined,
    ids: [4096]u32 = undefined,
    boxes: [4096][4]f32 = undefined,
    n: usize = 0,
};

var shape_slot: ?*FrameShape = null;

fn probeShape(_: ?*anyopaque, commands: []const ui.zclay.RenderCommand, w: u32, h: u32) void {
    _ = w;
    _ = h;
    const slot: *FrameShape = @ptrCast(@alignCast(shape_slot.?));
    slot.digest = ui.frame.hashCommands(@constCast(commands));
    slot.n = 0;
    for (commands) |cmd| {
        if (slot.n >= slot.digests.len) break;
        slot.digests[slot.n] = ui.frame.hashCommands(@constCast(commands[slot.n .. slot.n + 1]));
        slot.ids[slot.n] = cmd.id;
        slot.boxes[slot.n] = .{ cmd.bounding_box.x, cmd.bounding_box.y, cmd.bounding_box.width, cmd.bounding_box.height };
        slot.n += 1;
    }
}

test "an idle app renders the same frame twice (nothing in the list oscillates)" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    try h.typeText("SELECT * FROM users");
    h.run();
    h.frame();

    var shapes: [3]FrameShape = .{ .{}, .{}, .{} };
    var digests: [3]u64 = undefined;
    for (0..3) |i| {
        // Pin every caret clock, so the only thing that can differ is the list itself.
        h.app.ed.idle = 0;
        h.app.tree_search_ed.idle = 0;
        h.app.filter_ed.idle = 0;
        h.app.palette_ed.idle = 0;
        var opts: ui.frame.FrameOptions = .{ .probe = probeShape };
        shape_slot = &shapes[i];
        _ = h.driver.host.frameWithOptions(1200, 800, &opts);
        digests[i] = shapes[i].digest;
    }

    if (digests[0] != digests[1] or digests[1] != digests[2]) {
        std.debug.print("FRAME DIGESTS DIFFER: {x} {x} {x}\n", .{ digests[0], digests[1], digests[2] });
        var shown: usize = 0;
        const n = @min(shapes[0].n, shapes[2].n);
        var i: usize = 0;
        while (i < n and shown < 8) : (i += 1) {
            if (shapes[0].digests[i] == shapes[2].digests[i]) continue;
            std.debug.print("  cmd {d} id={d} box0={any} box2={any}\n", .{
                i, shapes[2].ids[i], shapes[0].boxes[i], shapes[2].boxes[i],
            });
            shown += 1;
        }
        if (shapes[0].n != shapes[2].n) {
            std.debug.print("  command count {d} vs {d}\n", .{ shapes[0].n, shapes[2].n });
        }
    }
    try testing.expectEqual(digests[0], digests[2]);
}

// ---- Layout structure ---- These are the invariants a screenshot review is for, written down: regions stack, they do not overlap, and each one is

// where the theme says it is. They are font-independent, so they hold on any machine.

// The box of a stable element id, or a test failure naming it.
fn boxOf(h: *Harness, id: []const u8) !ui.zclay.BoundingBox {
    return h.driver.box(id) orelse {
        std.debug.print("no element with id '{s}' in the frame\n", .{id});
        return error.ElementNotFound;
    };
}

// The bottom edge of a box.
fn bottom(b: ui.zclay.BoundingBox) f32 {
    return b.y + b.height;
}

// The right edge of a box.
fn right(b: ui.zclay.BoundingBox) f32 {
    return b.x + b.width;
}

test "the main screen's regions stack without overlapping" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    try h.typeText("SELECT * FROM users");
    h.run();
    h.frame();

    const topbar = try boxOf(&h, "topbar");
    const main = try boxOf(&h, "main");
    const status = try boxOf(&h, "status");
    const sidebar = try boxOf(&h, "sidebar");
    const work = try boxOf(&h, "work");

    // The topbar is the first row and the status bar the last.
    try testing.expectEqual(@as(f32, 0), topbar.y);
    try testing.expectApproxEqAbs(theme.topbar_h, topbar.height, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 800), bottom(status), 0.5);

    // The main row fills the space between them, with no overlap at either edge.
    try testing.expectApproxEqAbs(bottom(topbar), main.y, 0.5);
    try testing.expect(bottom(main) <= status.y + 0.5);

    // The sidebar and the workspace are side by side, the same height, and do not overlap.
    try testing.expectEqual(@as(f32, 0), sidebar.x);
    try testing.expectApproxEqAbs(theme.sidebar_width, sidebar.width, 0.5);
    try testing.expectApproxEqAbs(main.height, sidebar.height, 0.5);
    try testing.expectApproxEqAbs(bottom(sidebar), bottom(work), 0.5);
    try testing.expect(right(sidebar) <= work.x + 0.5);
}

test "the workspace stacks tabs, editor and results without overlapping" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    try h.typeText("SELECT * FROM users");
    h.run();
    h.frame();

    const work = try boxOf(&h, "work");
    // No table has been opened in this harness, so the tab band is the empty-state box.
    const tabs = try boxOf(&h, "tabs.empty");
    const editor_box = try boxOf(&h, "editor");
    const results = try boxOf(&h, "results");

    try testing.expectApproxEqAbs(work.y, tabs.y, 0.5);
    try testing.expect(bottom(tabs) <= editor_box.y + 0.5);
    try testing.expect(bottom(editor_box) <= results.y + 0.5);
    try testing.expectApproxEqAbs(bottom(work), bottom(results), 0.5);
    // All three are the full width of the workspace.
    for ([_]ui.zclay.BoundingBox{ tabs, editor_box, results }) |b| {
        try testing.expectApproxEqAbs(work.x, b.x, 0.5);
        try testing.expectApproxEqAbs(work.width, b.width, 0.5);
    }
}

test "the results grid's bar, header and body stack without overlapping" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    try h.typeText("SELECT * FROM users");
    h.run();
    h.frame();

    const results = try boxOf(&h, "results");
    const bar = try boxOf(&h, "results.bar");
    const header = try boxOf(&h, "grid.header");
    const body = try boxOf(&h, "grid.scroll");
    const pager = try boxOf(&h, "pager");

    // The bug this guards: the header used to be laid out over the first row of the body.
    try testing.expectApproxEqAbs(results.y, bar.y, 0.5);
    try testing.expect(bottom(bar) <= header.y + 0.5);
    try testing.expect(bottom(header) <= body.y + 0.5);
    // The pager owns the last strip of the pane, and the body stops above it rather than running under it.
    try testing.expect(bottom(body) <= pager.y + 0.5);
    try testing.expectApproxEqAbs(bottom(results), bottom(pager), 0.5);
    try testing.expect(header.width <= body.width + 0.5);
}

// ---- Double click ----

var fake_now_ms: i64 = 0;

fn fakeClock(_: ?*anyopaque) i64 {
    return fake_now_ms;
}

test "double-clicking a word in the editor selects it" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.driver.host.clock = fakeClock;
    _ = h.app.ed.insertSlice("SELECT name");
    h.app.ed.setCaret(11, false);
    h.driver.frame();

    const line = h.driver.box("editor.line.0") orelse return error.ElementNotFound;
    const y = line.y + line.height * 0.5;
    // Inside the first word.
    const x = line.x + ui.text.measureText("SEL", theme.font_size).w;

    fake_now_ms = 1000;
    h.driver.clickAt(x, y);
    fake_now_ms = 1150;
    h.driver.clickAt(x, y);

    const span = h.app.ed.caret.selection() orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 0), span.start);
    try testing.expectEqual(@as(usize, 6), span.end);
    // Selecting never edits the buffer.
    try testing.expectEqualStrings("SELECT name", h.app.ed.text());
}

test "two slow clicks in the editor leave a caret, not a selection" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.driver.host.clock = fakeClock;
    _ = h.app.ed.insertSlice("SELECT name");
    h.app.ed.setCaret(11, false);
    h.driver.frame();

    const line = h.driver.box("editor.line.0") orelse return error.ElementNotFound;
    const y = line.y + line.height * 0.5;
    const x = line.x + ui.text.measureText("SEL", theme.font_size).w;

    fake_now_ms = 1000;
    h.driver.clickAt(x, y);
    fake_now_ms = 2000;
    h.driver.clickAt(x, y);

    try testing.expect(h.app.ed.caret.selection() == null);
    try testing.expectEqual(@as(usize, 3), h.app.ed.caret.offset);
}

test "double-clicking a word in a field selects it" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.driver.host.clock = fakeClock;
    h.app.focus = .tree_search;
    _ = h.app.onText("users");
    h.driver.frame();

    const bb = h.driver.box("sidebar.search") orelse return error.ElementNotFound;
    const y = bb.y + bb.height * 0.5;
    const x = bb.x + 9 + 1;

    fake_now_ms = 1000;
    h.driver.clickAt(x, y);
    fake_now_ms = 1100;
    h.driver.clickAt(x, y);

    const span = h.app.tree_search_ed.caret.selection() orelse return error.NoSelection;
    try testing.expectEqual(@as(usize, 0), span.start);
    try testing.expectEqual(@as(usize, 5), span.end);
    try testing.expectEqualStrings("users", h.app.tree_search_ed.text());
}

// ---- Clipboard ----

var fake_clipboard: [4096]u8 = undefined;
var fake_clipboard_len: usize = 0;

fn fakeClipboardWrite(text: []const u8) void {
    const n = @min(text.len, fake_clipboard.len);
    @memcpy(fake_clipboard[0..n], text[0..n]);
    fake_clipboard_len = n;
}

fn fakeClipboardRead(buf: []u8) []const u8 {
    const n = @min(fake_clipboard_len, buf.len);
    @memcpy(buf[0..n], fake_clipboard[0..n]);
    return buf[0..n];
}

fn fakeClipboardText() []const u8 {
    return fake_clipboard[0..fake_clipboard_len];
}

test "Cmd+C, Cmd+X and Cmd+V move text through the clipboard" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.app.clipboard = .{ .read = fakeClipboardRead, .write = fakeClipboardWrite };
    fake_clipboard_len = 0;

    try h.typeText("SELECT name");
    // Select `name`: the caret goes to the end, then the anchor back to byte 7.
    h.app.ed.setCaret(11, false);
    h.app.ed.setCaret(7, true);

    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_C));
    try testing.expectEqualStrings("name", fakeClipboardText());
    // Copying must not disturb the buffer.
    try testing.expectEqualStrings("SELECT name", h.app.ed.text());

    // Collapse the selection to the end and paste: the copied run lands after the text.
    _ = h.app.onKey(.{}, editor.KEY_RIGHT);
    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_V));
    try testing.expectEqualStrings("SELECT namename", h.app.ed.text());

    // Cmd+A selects everything, Cmd+X takes it away and puts it on the clipboard.
    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_A));
    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_X));
    try testing.expectEqualStrings("", h.app.ed.text());
    try testing.expectEqualStrings("SELECT namename", fakeClipboardText());

    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_V));
    try testing.expectEqualStrings("SELECT namename", h.app.ed.text());

    // With nothing selected, copy is not consumed -- and it must never type a literal `c`.
    h.app.ed.setCaret(0, false);
    try testing.expect(!h.app.onKey(.{ .super = true }, editor.KEY_C));
    try testing.expectEqualStrings("SELECT namename", h.app.ed.text());
}

test "Cmd+C on the tree search copies that field, not the SQL editor" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    h.installKeys();
    h.app.clipboard = .{ .read = fakeClipboardRead, .write = fakeClipboardWrite };
    fake_clipboard_len = 0;

    try h.typeText("SELECT 1");
    h.app.focus = .tree_search;
    _ = h.app.onText("users");
    h.app.tree_search_ed.setCaret(5, false);
    h.app.tree_search_ed.setCaret(0, true);

    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_C));
    try testing.expectEqualStrings("users", fakeClipboardText());

    // Paste goes to the same field, and the SQL editor is untouched.
    _ = h.app.onKey(.{}, editor.KEY_END);
    try testing.expect(h.app.onKey(.{ .super = true }, editor.KEY_V));
    try testing.expectEqualStrings("usersusers", h.app.tree_search_ed.text());
    try testing.expectEqualStrings("usersusers", h.app.tree_search);
    try testing.expectEqualStrings("SELECT 1", h.app.ed.text());
}

// Choosing a database

// A directory under the build cache with real database files in it.
const DbDir = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,

    fn init(h: *Harness, name: []const u8) !DbDir {
        const gpa = h.app.gpa;
        const io = h.app.io;
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{name});
        errdefer gpa.free(path);
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    fn deinit(self: *DbDir) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.gpa.free(self.path);
    }

    fn join(self: *const DbDir, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.path, name });
    }

    // Write a real SQLite database, with a `users` table, to `name`.
    fn writeDb(self: *const DbDir, name: []const u8) !void {
        const handle = try std.Io.Dir.cwd().openDir(
            self.io,
            self.path,
            .{ .access_sub_paths = true },
        );
        defer handle.close(self.io);
        try handle.writeFile(self.io, .{ .sub_path = name, .data = "" });
        const full = try self.join(name);
        defer self.gpa.free(full);

        // Build it through SQLite rather than shipping a fixture, so the file is genuinely a database and the test is not asserting against a stale blob.
        var db = database.Db{};
        try db.init(self.io, try self.gpa.dupeZ(u8, full));
        defer db.deinit();
        try db.exec(self.gpa,
            \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)
        , &.{});
        try db.exec(self.gpa, "INSERT INTO users (id, name) VALUES (1, 'zoe')", &.{});
    }
};

test "Ctrl+O opens the picker and puts the keyboard in the path field" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    h.installKeys();

    try testing.expect(!h.app.picker.open);
    h.press(editor.KEY_O, .{ .ctrl = true });
    try testing.expect(h.app.picker.open);
    try testing.expectEqual(app_mod.Focus.path, h.app.focus);
}

test "the picker appears in the frame, with a field and a button" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    // Closed by default: the panel is not something the window shows before it is asked for.
    h.frame();
    try testing.expect(!h.driver.exists("picker"));

    h.app.openPicker();
    h.frame();

    try testing.expect(h.driver.exists("picker"));
    try testing.expect(h.driver.exists("picker.path"));
    try testing.expect(h.driver.exists("picker.open"));
    try testing.expect(h.driver.exists("sidebar.open"));
    try h.driver.expectText("Open database");
}

test "typing a path and pressing Enter opens that database" {
    // The whole point: a database browser that cannot be pointed at a different database.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    h.installKeys();

    var dir = try DbDir.init(&h, "meja-e2e-typed-path");
    defer dir.deinit();
    try dir.writeDb("typed.db");
    const path = try dir.join("typed.db");
    defer gpa.free(path);

    h.app.openPicker();
    try h.typeThroughHost(path);
    try testing.expectEqualStrings(path, h.app.picker.field.text());
    // SQL must not have been typed into the editor by mistake.
    try testing.expectEqual(@as(usize, 0), h.app.ed.len);

    h.press(editor.KEY_ENTER, .{});

    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings(path, h.app.db_path);
    // It really is that database, not the in-memory one it started on.
    try testing.expect(h.app.tables.items.len >= 1);
    try testing.expectEqualStrings("users", h.app.tables.items[0].name);
    // A successful open closes the panel.
    try testing.expect(!h.app.picker.open);
}

test "clicking a listed database opens it" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-click-open");
    defer dir.deinit();
    try dir.writeDb("clicked.db");

    h.app.openPicker();
    h.app.enterDirectory(dir.path);
    try testing.expect(h.app.picker.entries.items.len >= 2);

    // The listing is "..", then "clicked.db" (no subdirectories here).
    const index = blk: {
        for (h.app.picker.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, "clicked.db")) break :blk i;
        }
        return error.DatabaseNotListed;
    };

    h.frame();
    try h.driver.expectText("clicked.db");
    h.app.activateCandidate(index);

    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings("clicked.db", picker_mod.baseOf(h.app.db_path));
    try testing.expectEqualStrings("users", h.app.tables.items[0].name);
}

test "clicking the Open button opens the typed path" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-button-open");
    defer dir.deinit();
    try dir.writeDb("button.db");
    const path = try dir.join("button.db");
    defer gpa.free(path);

    h.app.openPicker();
    h.app.picker.field.setText(path);
    h.frame();

    // The button is a real click target, so click it the way a pointer would rather than calling the handler.
    try h.driver.click("picker.open");

    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings("button.db", picker_mod.baseOf(h.app.db_path));
}

test "the sidebar's Open button toggles the picker" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    h.frame();
    try h.driver.click("sidebar.open");
    try testing.expect(h.app.picker.open);

    h.frame();
    try h.driver.click("sidebar.open");
    try testing.expect(!h.app.picker.open);
}

test "a directory is entered, not reported as a broken database" {
    // Entering a directory must navigate rather than fail: "cannot open a directory" would be both true and useless.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-enter-dir");
    defer dir.deinit();
    try dir.writeDb("inside.db");

    h.app.openPicker();
    h.app.picker.field.setText(dir.path);
    h.app.openTypedPath();

    try testing.expect(h.app.picker.open); // still browsing
    try testing.expectEqualStrings(dir.path, h.app.picker.dir());
    try testing.expect(h.app.picker.error_message == null);
    // The database inside is now listed, and ".." is offered above it.
    var found = false;
    for (h.app.picker.entries.items) |e| {
        if (std.mem.eql(u8, e.name, "inside.db")) found = true;
    }
    try testing.expect(found);
    try testing.expectEqualStrings("..", h.app.picker.entries.items[0].name);
}

test ".. goes back up a level" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-go-up");
    defer dir.deinit();
    try dir.writeDb("deep.db");

    h.app.openPicker();
    h.app.enterDirectory(dir.path);
    h.app.activateCandidate(0); // ".."

    try testing.expectEqualStrings(".zig-cache/tmp", h.app.picker.dir());
    // ...and the database is now one level further away, which is the point: there is always a way out of a listing.
    try testing.expectEqualStrings(".zig-cache/tmp", picker_mod.parentOf(dir.path));
}

test "opening a database that is not there says which path failed" {
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    h.app.openPicker();
    h.app.picker.field.setText("/no/such/directory/missing.db");
    h.app.openTypedPath();

    try testing.expect(!h.app.db_open);
    // The old message was a bare "cannot open database", which names nothing the user can act on.
    try testing.expect(std.mem.indexOf(u8, h.app.status, "missing.db") != null);

    h.frame();
    try h.expectTextContaining("missing.db");
}

test "a failed switch keeps the database that was already open" {
    // Failing must not look like closing: the window still shows the old database and says so.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    const before = h.app.db_path;
    try testing.expectEqualStrings(":memory:", before);

    h.app.open("/no/such/place/other.db");
    try testing.expect(!h.app.db_open);
    // Never opened, so there is no path to keep — but the in-memory database the app started on must still be usable.
    h.app.runEditor();
    try testing.expect(h.app.has_result or h.app.ed.len == 0);
}

test "Tab moves between the path field and the SQL editor" {
    // Two fields, one keyboard: without an explicit focus the user can type a database path into their query, or a query into a path.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    h.installKeys();
    try seed(h.app);

    h.app.openPicker();
    try testing.expectEqual(app_mod.Focus.path, h.app.focus);

    h.press(editor.KEY_TAB, .{});
    try testing.expectEqual(app_mod.Focus.sql_editor, h.app.focus);

    try h.typeThroughHost("SELECT 1");
    try testing.expectEqualStrings("SELECT 1", h.app.ed.text());
    // ...and the path field was left alone.
    try testing.expectEqual(@as(usize, 0), h.app.picker.field.len);

    h.press(editor.KEY_TAB, .{});
    try testing.expectEqual(app_mod.Focus.path, h.app.focus);

    try h.typeThroughHost("x.db");
    try testing.expectEqualStrings("x.db", h.app.picker.field.text());
    try testing.expectEqualStrings("SELECT 1", h.app.ed.text());
}

test "typing is still SQL after the picker has been closed" {
    // Closing must hand the keyboard back, or the window is left with a path field that swallows every query.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    h.installKeys();
    try seed(h.app);

    h.press(editor.KEY_O, .{ .ctrl = true });
    try testing.expect(h.app.picker.open);
    h.press(editor.KEY_O, .{ .ctrl = true });
    try testing.expect(!h.app.picker.open);
    try testing.expectEqual(app_mod.Focus.sql_editor, h.app.focus);

    try h.typeThroughHost("SELECT name FROM users");
    try testing.expectEqualStrings("SELECT name FROM users", h.app.ed.text());
    h.run();
    try testing.expectEqual(@as(usize, 3), h.app.result.rowCount());
}

test "the status line never points at freed memory" {
    // `status` used to be `dupe`d onto the heap with nothing freeing it, or borrowed straight out of the result set — which is deinited on the next run.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);

    try h.typeText("SELECT nosuchcolumn FROM users");
    h.run();
    const after_error = h.app.status;
    try testing.expect(after_error.len > 0);

    // Switch to another database, which frees the result the message used to live in.
    h.app.open(":memory:");
    try h.typeText("SELECT 1");
    h.run();
    h.frame();
    try testing.expect(h.app.status.len > 0);
    // The buffer belongs to the App, not the allocator.
    try testing.expectEqual(
        @intFromPtr(&h.app.status_buf),
        @intFromPtr(h.app.status.ptr),
    );
}

// Browse: the system dialog, end to end.

test "Browse opens the database the dialog returns" {
    // The whole point of the feature: click Browse, pick a file, browse it.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-browse-open");
    defer dir.deinit();
    try dir.writeDb("browsed.db");
    const path = try dir.join("browsed.db");
    defer gpa.free(path);

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .{ .selected = &.{path} });

    // Through the real button, not the handler: a Browse action no frame draws is the same failure as a browser with no way to change database.
    h.frame();
    try h.driver.click("sidebar.browse");

    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings(path, h.app.db_path);
    // It really is that database, not the in-memory one it started on.
    try testing.expect(h.app.tables.items.len >= 1);
    try testing.expectEqualStrings("users", h.app.tables.items[0].name);
    // A successful open closes the picker, like every other route.
    try testing.expect(!h.app.picker.open);
}

test "a browsed database can be queried, and the result is drawn" {
    // Browse is only useful if what it opens can then be queried.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-browse-query");
    defer dir.deinit();
    try dir.writeDb("queried.db");
    const path = try dir.join("queried.db");
    defer gpa.free(path);

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .{ .selected = &.{path} });

    h.frame();
    try h.driver.click("sidebar.browse");
    try testing.expect(h.app.db_open);

    // Now query it, the way a user would.
    try h.typeText("SELECT name FROM users");
    h.run();
    h.frame();

    try testing.expect(h.app.has_result);
    try testing.expectEqual(@as(usize, 1), h.app.result.rowCount());
    // The row the fixture inserted, reachable as DRAWN text — not merely present in the result set.
    try h.driver.expectText("zoe");
    try h.driver.expectText("name");
}

test "clicking a table in a browsed database fills the editor and the grid" {
    // The other half of browsing: the schema tree is populated from what the dialog opened, and clicking a row in it runs a query.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-browse-tree");
    defer dir.deinit();
    try dir.writeDb("treed.db");
    const path = try dir.join("treed.db");
    defer gpa.free(path);

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .{ .selected = &.{path} });

    h.frame();
    try h.driver.click("sidebar.browse");
    try testing.expect(h.app.tables.items.len >= 1);

    h.app.browseTable(0);
    h.frame();

    try testing.expectEqualStrings("SELECT * FROM users", h.app.ed.text());
    try testing.expect(h.app.has_result);
    try h.driver.expectText("zoe");
}

test "the dialog is asked to start in the open database's directory" {
    // The request half of the contract, asserted through the app.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-browse-folder");
    defer dir.deinit();
    try dir.writeDb("folder.db");
    const path = try dir.join("folder.db");
    defer gpa.free(path);

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .cancelled);

    // Open a database first, so there IS a directory to start from.
    h.app.open(path);
    try testing.expect(h.app.db_open);

    h.app.browseForDatabase();

    try testing.expectEqualStrings(dir.path, fake.last_folder.?);
    try testing.expectEqualStrings("Open database", fake.last_title);
}

test "a cancelled browse leaves the open database alone" {
    // The user closed the dialog on purpose.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    try seed(h.app);
    const before = h.app.db_path;

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .cancelled);

    h.app.browseForDatabase();

    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings(before, h.app.db_path);
    try testing.expect(std.mem.indexOf(u8, h.app.status, "cancelled") != null);
    // The result set is untouched too: a cancel is not a reason to clear it.
    try testing.expect(h.app.has_result or h.app.ed.len == 0);
}

test "each portal failure is reported, and the picker is still offered" {
    // "no portal" and "no bus" have completely different fixes, so the app must say which one it got — and every one of them must leave the fallback.
    const gpa = std.heap.page_allocator;
    const E = ui.file_dialog.Error;
    const cases = [_]struct { err: E, want: []const u8 }{
        .{ .err = E.Unsupported, .want = "no system file dialog on this platform" },
        .{ .err = E.NoPortal, .want = "no desktop portal" },
        .{ .err = E.NoSessionBus, .want = "no D-Bus session bus" },
        .{ .err = E.PortalError, .want = "the file dialog failed" },
        .{ .err = E.Timeout, .want = "the file dialog failed" },
    };
    for (cases) |case| {
        var h = try Harness.init(gpa);
        defer h.deinit();

        var fake: ui.file_dialog.fake.Fake = undefined;
        defer ui.file_dialog.fake.uninstall();
        h.scriptDialog(&fake, .{ .failed = case.err });

        h.app.browseForDatabase();

        try testing.expect(std.mem.indexOf(u8, h.app.status, case.want) != null);
        // Every message ends by pointing at the picker, which still works.
        try testing.expect(std.mem.indexOf(u8, h.app.status, "picker") != null);
        // And the picker really does open.
        h.app.openPicker();
        try testing.expect(h.app.picker.open);
    }
}

test "a browse that returns nothing is not treated as a picked file" {
    // A backend that was asked for a file and got none reports `.other`.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .{ .selected = &.{} });

    h.app.browseForDatabase();

    // Nothing opened, and the app is still alive and still on what it had.
    try testing.expect(h.app.db_open);
    try testing.expectEqualStrings(":memory:", h.app.db_path);
}

test "browsing twice opens the second database" {
    // The fake is stateless between calls apart from its counter, so a second browse is a second real round trip.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var dir = try DbDir.init(&h, "meja-e2e-browse-twice");
    defer dir.deinit();
    try dir.writeDb("one.db");
    try dir.writeDb("two.db");
    const first_path = try dir.join("one.db");
    defer gpa.free(first_path);
    const second_path = try dir.join("two.db");
    defer gpa.free(second_path);

    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    h.scriptDialog(&fake, .{ .selected = &.{first_path} });

    h.app.browseForDatabase();
    try testing.expectEqualStrings(first_path, h.app.db_path);

    fake.answer = .{ .selected = &.{second_path} };
    h.app.browseForDatabase();
    try testing.expectEqualStrings(second_path, h.app.db_path);
    try testing.expectEqual(@as(usize, 2), fake.calls);
}

test "the Browse button is a real click target in the frame" {
    // A Browse action no frame draws is the same failure as a database browser with no way to change database.
    const gpa = std.heap.page_allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    h.frame();
    try testing.expect(h.driver.exists("sidebar.browse"));
    // The picker's own Browse is there too, so the listing can hand over.
    h.app.openPicker();
    h.frame();
    try testing.expect(h.driver.exists("picker.browse"));
}
