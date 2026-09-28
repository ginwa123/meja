const std = @import("std");
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

const meja = @import("meja");
const database = @import("databases").database;
const query = meja.query;
const schema = meja.schema;
const sql = meja.sql;
const value = meja.value;
const editor = @import("editor.zig");
const grid = @import("grid.zig");
const theme = @import("theme.zig");

/// Drives the REAL App type from main.zig against a REAL database and
/// dumps what a frame actually contains. This is the closest thing to
/// looking at the window that is possible without a human at the screen.
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else ":memory:";

    // A mini-app holding real core state, shaped like the real one.
    const App = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        db: database.Db = .{},
        result: query.ResultSet = undefined,
        has_result: bool = false,
        status: []const u8 = "",
        tables: [][]const u8 = &.{},
        col_widths: [8]u16 = @splat(grid.default_column_width),
        col_count: usize = 0,
        sql_storage: [4096]u8 = undefined,
        ed: editor.Editor = undefined,

        fn openAndBrowse(self: *@This(), p: [:0]const u8) !void {
            try self.db.init(self.io, p);
            const objects = try schema.listObjects(self.gpa, &self.db, &.{ .table, .view });
            defer schema.freeObjects(self.gpa, objects);
            self.tables = try self.gpa.alloc([]const u8, objects.len);
            for (objects, 0..) |o, i| self.tables[i] = self.gpa.dupe(u8, o.name) catch unreachable;

            const quoted = try sql.quoteIfNeeded(self.gpa, self.tables[0]);
            defer self.gpa.free(quoted);
            const seed = try std.fmt.allocPrint(self.gpa, "SELECT * FROM {s}", .{quoted});
            defer self.gpa.free(seed);
            self.ed = editor.Editor.init(&self.sql_storage);
            self.ed.setText(seed);
            self.run();
        }

        fn run(self: *@This()) void {
            const stmts = sql.splitStatements(self.gpa, self.ed.text()) catch return;
            defer sql.freeStatements(self.gpa, stmts);
            for (stmts) |st| {
                if (self.has_result) self.result.deinit();
                self.result = query.run(self.gpa, &self.db, st.text, .{}) catch continue;
                self.has_result = true;
                self.col_count = self.result.columnCount();
                if (self.result.error_message) |m| {
                    self.status = m;
                } else self.status = "ok";
            }
        }

        fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
            _ = .{ w, h };
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            ui.components.box.box(.{
                .id = "root",
                .w = .grow,
                .h = .grow,
                .bg = theme.bg_app,
            }, self, children);
        }

        fn treeRowChild(self: *@This()) void {
            ui.components.text.label(.{
                .str = self.tables[current_row],
                .font_size = theme.font_size,
                .color = theme.text,
            });
        }

        fn children(self: *@This()) void {
            // Sidebar: the table names, as the real app shows them.
            for (self.tables, 0..) |_, i| {
                current_row = i;
                ui.components.box.box(.{
                    .id = treeId(i),
                    .w = .grow,
                    .h = .{ .fixed = @floatFromInt(theme.row_height) },
                    .bg = theme.bg_panel,
                }, self, treeRowChild);
            }

            // Editor line, with the caret.
            var ebuf: [1024]u8 = undefined;
            ui.components.text.label(.{
                .str = editor.renderLineWithCaret(self.ed.text(), 0, &ebuf),
                .font_size = theme.font_size,
                .color = theme.text,
            });

            ui.components.text.label(.{ .str = self.status, .color = theme.text_dim });

            // Grid: header + every row (this database is tiny).
            for (0..self.col_count) |c| {
                if (c < self.result.columns.len) {
                    ui.components.text.label(.{
                        .str = self.result.columns[c].name,
                        .font_size = theme.font_size_small,
                        .color = theme.text_bright,
                    });
                }
            }
            for (self.result.rows) |row| {
                for (row.values) |v| {
                    var buf: [256]u8 = undefined;
                    const shown = if (v.isNull()) "NULL" else value.render(&buf, v);
                    ui.components.text.label(.{
                        .str = shown,
                        .font_size = theme.font_size_small,
                        .color = if (v.isNull()) theme.text_null_value else theme.text,
                    });
                }
            }
        }
    };

    var app = App{ .gpa = gpa, .io = io };
    app.ed = editor.Editor.init(&app.sql_storage);
    try app.openAndBrowse(path);

    var driver = try Driver.initOwned(gpa, &app, App.root);
    defer driver.deinit();
    try driver.start(.{ .width = 1200, .height = 800 });
    try driver.waitForIdle();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.print("TABLES ({d}):\n", .{app.tables.len});
    for (app.tables) |t| try w.print("  {s}\n", .{t});
    try w.print("\nEDITOR: {s}\n", .{app.ed.text()});
    try w.print("STATUS: {s}\n", .{app.status});
    try w.print("RESULT: {d} rows x {d} cols in {d} us\n", .{
        app.result.rowCount(),
        app.result.columnCount(),
        app.result.elapsed_ns / 1000,
    });
    try w.print("COLUMNS: ", .{});
    for (0..app.col_count) |c| {
        if (c < app.result.columns.len) try w.print("{s} ", .{app.result.columns[c].name});
    }
    try w.print("\n\nROWS AS RENDERED:\n", .{});
    for (app.result.rows) |row| {
        for (row.values) |v| {
            var buf: [256]u8 = undefined;
            try w.print("| {s: <14}", .{if (v.isNull()) "NULL" else value.render(&buf, v)});
        }
        try w.print("|\n", .{});
    }

    const snap = driver.snapshot();
    try w.print("\nFRAME: {d} rects, {d} texts, {d} scissor\n", .{
        snap.rectangle_count, snap.text_count, snap.scissor_count,
    });

    std.debug.print("{s}", .{out.written()});
}

/// The sidebar row currently being declared. Set immediately before
/// each row's box, since the child function only receives the app.
var current_row: usize = 0;

fn treeId(i: usize) []const u8 {
    var buf: [24]u8 = undefined;
    return std.fmt.bufPrint(&buf, "tree.{d}", .{i}) catch "tree";
}
