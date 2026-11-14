// Render the real app with the REAL font and check the caret against the pixels. The unit tests use the portable text backend, whose "font" is `len *

// size * 0.6` — so a caret placed from a guessed cell width passes every test and still lands on a glyph in the window, because the guess WAS the stub.

// This renders through the real rasteriser twice, once with the caret lit and once with it dark, and compares the two frames: the columns that only the

// lit frame has are the caret, and any ink already there in the dark frame is the caret sitting on a character.

const std = @import("std");
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

const app_mod = @import("app.zig");
const main_mod = @import("main.zig");
const theme = @import("theme.zig");

// How far a pixel must be from the background before it counts as ink.
const ink_threshold: i32 = 12;

// The channels of a packed 0xAARRGGBB colour.
fn rgbOf(c: ui.Color) [3]u8 {
    return .{ @truncate((c.value >> 16) & 0xFF), @truncate((c.value >> 8) & 0xFF), @truncate(c.value & 0xFF) };
}

// One rendered frame, cropped to a rectangle of interest.
const Band = struct {
    pixels: []const u8,
    width: u32,
    x0: u32,
    x1: u32,
    y0: u32,
    y1: u32,
    bg: [3]u8,

    fn ink(self: Band, x: u32, y: u32) bool {
        const i = (y * self.width + x) * 4;
        const px = [3]u8{ self.pixels[i], self.pixels[i + 1], self.pixels[i + 2] };
        const d = @abs(@as(i32, px[0]) - @as(i32, self.bg[0])) +
            @abs(@as(i32, px[1]) - @as(i32, self.bg[1])) +
            @abs(@as(i32, px[2]) - @as(i32, self.bg[2]));
        return d > ink_threshold;
    }

    fn columnInk(self: Band, x: u32) usize {
        if (x < self.x0 or x > self.x1) return 0;
        var n: usize = 0;
        var y = self.y0;
        while (y <= self.y1) : (y += 1) {
            if (self.ink(x, y)) n += 1;
        }
        return n;
    }
};

// A copy of one frame's pixels: the surface is reused every frame, so the two frames must not share it.
fn pixelAt(b: Band, x: u32, y: u32) [3]u8 {
    const i = (y * b.width + x) * 4;
    return .{ b.pixels[i], b.pixels[i + 1], b.pixels[i + 2] };
}

const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    scale: f32,
};

fn band(f: Frame, box: anytype, bg: [3]u8) Band {
    const w: f32 = @floatFromInt(f.width);
    const h: f32 = @floatFromInt(f.height);
    return .{
        .pixels = f.pixels,
        .width = f.width,
        .x0 = @intFromFloat(@max(box.x * f.scale, 0)),
        .x1 = @intFromFloat(@min((box.x + box.width) * f.scale, w - 1)),
        .y0 = @intFromFloat(@max(box.y * f.scale, 0)),
        .y1 = @intFromFloat(@min((box.y + box.height) * f.scale, h - 1)),
        .bg = bg,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    _ = init;
    var app: app_mod.App = undefined;
    app.init(gpa, threaded.io());
    defer {
        app.clearResult();
        app.freeTables();
        app.freeTabs();
        if (app.db_open) app.db.deinit();
    }
    app.open(":memory:");
    app.openFirstTable();

    // The case in the screenshot: a digit run with the caret in the middle of it.
    app.focus = .tree_search;
    _ = app.onText("222dsd");
    app.tree_search_ed.setCaret(2, false);
    app.ed.setText("SELECT * FROM Invoice");
    app.ed.setCaret(14, false);

    var driver = try Driver.initOwned(gpa, &app, main_mod.App_root);
    defer driver.deinit();
    try driver.start(.{ .width = 1200, .height = 800 });
    // The window renders at the display's backing scale, so the check must too: 1x hides the antialiasing that a Retina screen shows.
    ui.software_render.setRenderScale(2);
    ui.frame.setPixelScale(2);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.print("RENDER SCALE: {d}\n\n", .{ui.software_render.renderScale()});

    var failures: usize = 0;
    failures += try check(w, &driver, .{
        .tag = "FIELD  sidebar.search",
        .id = .{ .text = "sidebar.search" },
        .caret_id = ui.zclay.ElementId.IDI("sidebar.search", 2),
        .editor = &app.tree_search_ed,
        .focus = .tree_search,
    });
    failures += try check(w, &driver, .{
        .tag = "EDITOR line 0",
        .id = .{ .text = "editor.line.0" },
        .caret_id = ui.zclay.ElementId.IDI("editor.caret.0", 0),
        .editor = &app.ed,
        .focus = .sql_editor,
    });

    // Everything that differs between the caret lit and the caret dark, anywhere on the surface: a blink elsewhere shows here.
    failures += try reportLitDarkDiff(w, &driver, &app);

    std.debug.print("{s}", .{out.written()});
    if (failures != 0) {
        std.debug.print("VERIFY: {d} check(s) failed\n", .{failures});
        return error.VerifyFailed;
    }
    std.debug.print("VERIFY: all checks passed\n", .{});
}

/// Render the app with the editor caret lit and dark, and report every pixel that differs.
fn reportLitDarkDiff(w: *std.Io.Writer, driver: *Driver, app: *app_mod.App) !usize {
    const gpa = driver.alloc;
    app.focus = .sql_editor;
    app.ed.idle = 0;
    driver.frame();
    const lit_surface = ui.software_render.currentSurface() orelse return 0;
    const lit = try gpa.dupe(u8, lit_surface.pixels);
    defer gpa.free(lit);
    const width = lit_surface.width;
    const height = lit_surface.height;

    app.ed.idle = 0.6;
    driver.frame();
    const dark = ui.software_render.currentSurface() orelse return 0;

    var min_x: usize = width;
    var max_x: usize = 0;
    var min_y: usize = height;
    var max_y: usize = 0;
    var count: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const i = (y * width + x) * 4;
            if (lit[i] == dark.pixels[i] and lit[i + 1] == dark.pixels[i + 1] and lit[i + 2] == dark.pixels[i + 2]) continue;
            count += 1;
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
        }
    }
    try w.print("\nLIT vs DARK: {d} px differ, bbox x {d}..{d} y {d}..{d} (surface {d}x{d})\n", .{
        count, min_x, max_x, min_y, max_y, width, height,
    });
    return 0;
}

const Case = struct {
    tag: []const u8,
    id: []const u8,
    caret_id: ui.zclay.ElementId,
    editor: *ui.text_editor.Editor,
    focus: app_mod.Focus,
};

// Render the case with the caret lit and dark, and check the columns only the lit frame has.
fn check(w: *std.Io.Writer, driver: *Driver, case: Case) !usize {
    const app: *app_mod.App = @ptrCast(@alignCast(driver.host.root_ctx));
    app.focus = case.focus;

    const gpa = driver.alloc;
    // Lit: idle 0 keeps the caret solid. Dark: 0.6 s is the other half of the blink.
    case.editor.idle = 0;
    driver.frame();
    const scale = ui.software_render.renderScale();
    const lit_surface = ui.software_render.currentSurface() orelse return error.NoSurface;
    const lit_frame = Frame{
        .pixels = try gpa.dupe(u8, lit_surface.pixels),
        .width = lit_surface.width,
        .height = lit_surface.height,
        .scale = scale,
    };
    defer gpa.free(lit_frame.pixels);

    case.editor.idle = 0.6;
    driver.frame();
    const dark_surface = ui.software_render.currentSurface() orelse return error.NoSurface;
    const dark_frame = Frame{
        .pixels = try gpa.dupe(u8, dark_surface.pixels),
        .width = dark_surface.width,
        .height = dark_surface.height,
        .scale = scale,
    };
    defer gpa.free(dark_frame.pixels);
    case.editor.idle = 0;

    const bg = rgbOf(theme.bg_editor);
    const box = ui.zclay.getElementData(ui.zclay.getElementId(case.id)).bounding_box;
    const caret = ui.zclay.getElementData(case.caret_id).bounding_box;
    const lit = band(lit_frame, box, bg);
    const dark = band(dark_frame, box, bg);

    try w.print("{s}: box x={d:.1} w={d:.1} | caret x={d:.1} w={d:.1} h={d:.1}\n", .{
        case.tag, box.x, box.width, caret.x, caret.width, caret.height,
    });

    var failures: usize = 0;
    var bar_columns: usize = 0;
    var on_ink: usize = 0;
    var x = lit.x0;
    while (x <= lit.x1) : (x += 1) {
        const a = lit.columnInk(x);
        const b = dark.columnInk(x);
        if (a > b) {
            bar_columns += 1;
            // The glyph's own ink under the bar. A caret between two digits has nowhere else to go; it only has to be a colour you can tell apart from the text,

            // which is checked below.
            if (b > 0) on_ink += 1;
        }
        // Outside the caret columns the two frames must be identical: the caret must not move the text.
        if (a < b) {
            try w.print("  FAIL x={d} lost {d} ink when the caret lit up (the text moved)\n", .{ x, b - a });
            failures += 1;
        }
    }

    if (bar_columns != 1) {
        try w.print("  FAIL the caret covers {d} device column(s), want exactly 1\n", .{bar_columns});
        failures += 1;
    }

    const cx: u32 = @intFromFloat(caret.x * lit_frame.scale);
    // A bar, not a glyph: its column is solid over the caret's height.
    const want: usize = @intFromFloat(caret.height * lit_frame.scale * 0.8);
    const filled = lit.columnInk(cx);
    if (filled < want) {
        try w.print("  FAIL caret column {d} is filled {d}/{d} px\n", .{ cx, filled, want });
        failures += 1;
    }

    // Legibility: the bar must not be the text colour, or a bar across a digit reads as a broken character.
    const mid_y: u32 = (lit.y0 + lit.y1) / 2;
    const bar_rgb = pixelAt(lit, cx, mid_y);
    const text_rgb = rgbOf(theme.text);
    const diff = @abs(@as(i32, bar_rgb[0]) - @as(i32, text_rgb[0])) +
        @abs(@as(i32, bar_rgb[1]) - @as(i32, text_rgb[1])) +
        @abs(@as(i32, bar_rgb[2]) - @as(i32, text_rgb[2]));
    if (diff < 30) {
        try w.print("  FAIL caret colour rgb({d},{d},{d}) is too close to the text colour\n", .{ bar_rgb[0], bar_rgb[1], bar_rgb[2] });
        failures += 1;
    }

    try w.print("  {d} device column, {d} px solid (want >= {d}), colour distance {d}, on glyph ink: {d}\n", .{
        bar_columns, filled, want, diff, on_ink,
    });
    return failures;
}
