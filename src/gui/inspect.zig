//! Render one real frame of the real app and print what it drew.

const std = @import("std");
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

const app_mod = @import("app.zig");
const main_mod = @import("main.zig");
const value = @import("meja").value;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else ":memory:";

    var app: app_mod.App = undefined;
    app.init(gpa, threaded.io());
    defer {
        app.clearResult();
        app.freeTables();
        app.freeTabs();
        if (app.db_open) app.db.deinit();
    }
    app.open(path);
    app.openFirstTable();

    var driver = try Driver.initOwned(gpa, &app, main_mod.App_root);
    defer driver.deinit();
    try driver.start(.{ .width = 1200, .height = 800 });
    try driver.waitForIdle();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.print("DATABASE: {s}\n", .{if (app.db_open) app.db_path else "none"});
    try w.print("TABLES ({d}):\n", .{app.tables.items.len});
    for (app.tables.items) |t| try w.print("  {s}\n", .{t.name});

    try w.print("\nTREE ({d} rows):\n", .{app.tree_rows.items.len});
    for (app.tree_rows.items) |row| {
        var i: usize = 0;
        while (i < row.depth) : (i += 1) try w.print("  ", .{});
        try w.print("{s}{s}", .{ if (row.has_children) (if (row.expanded) "- " else "+ ") else "  ", row.label });
        if (row.meta.len > 0) try w.print("  [{s}]", .{row.meta});
        if (row.selected) try w.print("  *", .{});
        try w.print("\n", .{});
    }

    try w.print("\nEDITOR: {s}\n", .{app.ed.text()});
    try w.print("STATUS: {s}\n", .{app.status});
    if (app.has_result) {
        try w.print("RESULT: {d} rows x {d} cols in {d} us\n", .{
            app.result.rowCount(),
            app.result.columnCount(),
            app.result.elapsed_ns / 1000,
        });
        try w.print("COLUMNS: ", .{});
        for (app.result.columns) |c| try w.print("{s} ", .{c.name});
        try w.print("\n\nROWS AS RENDERED:\n", .{});
        for (app.result.rows) |row| {
            for (row.values) |v| {
                var buf: [256]u8 = undefined;
                try w.print("| {s: <14}", .{if (v.isNull()) "NULL" else value.render(&buf, v)});
            }
            try w.print("|\n", .{});
        }
    }

    const snap = driver.snapshot();
    try w.print("\nFRAME: {d} rects, {d} texts, {d} scissor\n", .{
        snap.rectangle_count, snap.text_count, snap.scissor_count,
    });

    std.debug.print("{s}", .{out.written()});
}
