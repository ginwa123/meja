const std = @import("std");
const ui = @import("glinlandui");
const box_mod = ui.components.box;
const text_mod = ui.components.text;
const button = ui.components.button;
const input_mod = ui.components.input;
const scroll_mod = ui.components.scroll;
const registry = ui.components.click_registry;
const tree_mod = ui.components.tree;
const tabs_mod = ui.components.tabs;
const badge_mod = ui.components.badge;

const cl = ui.zclay;
const app_mod = @import("../app.zig");
const LineClick = app_mod.LineClick;
const max_editor_lines = app_mod.max_editor_lines;
const App = app_mod.App;
const theme = @import("../theme.zig");
const grid = ui.table;
const editor = ui.text_editor;

pub fn editorPane(self: *App) void {
    const line_count = @max(self.ed.lineCount(), 1);
    const wanted = @as(f32, @floatFromInt(line_count)) * @as(f32, @floatFromInt(theme.row_height)) + 64;
    const cap = @as(f32, @floatFromInt(self.window_h)) * 0.45;

    box_mod.box(.{
        .id = "editor",
        .w = .grow,
        .h = .{ .fixed = @min(wanted, cap) },
        .direction = .column,
        .bg = theme.bg_editor,
        .gap = 0,
    }, self, editorPaneChildren);
}

pub fn editorPaneChildren(self: *App) void {
    editorBar(self);
    editorBody(self);
}

pub fn editorBar(self: *App) void {
    box_mod.box(.{
        .id = "editor.bar",
        .w = .grow,
        .h = .{ .fixed = theme.bar_h },
        .direction = .row,
        .bg = theme.bg_editor,
        .pad = 6,
        .gap = 8,
    }, self, editorBarChildren);
}

pub fn editorBarChildren(self: *App) void {
    text_mod.label(.{ .str = "QUERY", .font_size = theme.font_size_tiny, .color = theme.text_faint });
    text_mod.label(.{ .str = "Ctrl+Enter to run", .font_size = theme.font_size_tiny, .color = theme.text_ghost });
    box_mod.spacer("editor.bar.spacer");
    button.button(.{
        .id = "editor.run",
        .label = "Run",
        .font_size = theme.font_size_tiny,
        .bg = theme.bg_primary,
        .fg = theme.text_bright,
        .hover_bg = theme.bg_primary_hover,
        .pad_tb = 3,
        .pad_lr = 12,
        .on_click = onRunClick,
        .ctx = self,
    });
}

pub fn editorBody(self: *App) void {
    // The editor owns its caret clock, the same way a single-line field does; without this tick it could never blink.
    self.ed.idle += ui.frame.delta_s;
    box_mod.box(.{
        .id = "editor.body",
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_editor,
        .pad = 6,
        .gap = 0,
    }, self, editorBodyChildren);
}

pub fn editorBodyChildren(self: *App) void {
    const line_count = @max(self.ed.lineCount(), 1);
    for (0..@min(line_count, max_editor_lines)) |line| {
        const id = self.cellId("editor.line", line);
        self.line_clicks[line] = .{ .app = self, .line = line };
        box_mod.box(.{
            .id = id,
            .w = .grow,
            .h = .{ .fixed = theme.row_height },
            .direction = .row,
            .child_align = .{ .y = .center },
        }, &self.line_clicks[line], editorLineChildren);
        registry.registerClickDoubleCursor(cl.getElementId(id), onLineClick, onLineDoubleClick, &self.line_clicks[line], .text);
    }
}

/// Draw one editor line inside the box that owns its click target.
fn editorLineChildren(lc: *LineClick) void {
    const self = lc.app;
    const caret_line = self.ed.lineNumber(self.ed.caret.offset);
    editorLine(self, lc.line, lc.line == caret_line and self.focus == .sql_editor);
}

/// The byte offset in the clicked line that the pointer is over, or null when the line box is not laid out.
fn lineOffsetAtPointer(self: *App, line: usize) ?usize {
    const start = self.ed.lineStartAt(line);
    var end = start;
    while (end < self.ed.len and self.ed.buf[end] != '\n') end += 1;
    // The body is the box every line shares, and its padding is where the text starts.
    const body = cl.getElementData(cl.getElementId("editor.body"));
    if (!body.found) return null;
    const rel_x = @max(ui.frame.ptr_x - body.bounding_box.x - 6, 0);
    return start + offsetAtX(self.ed.buf[start..end], rel_x);
}

/// Place the caret from a click on a line: the column comes from x, the line is the one that was hit.
fn onLineClick(ctx: ?*anyopaque) void {
    const lc: *LineClick = @ptrCast(@alignCast(ctx.?));
    const self = lc.app;
    const at = lineOffsetAtPointer(self, lc.line) orelse return;
    self.ed.setCaret(at, false);
    self.ed.idle = 0;
    self.focus = .sql_editor;
}

/// Double click: select the word under the pointer, the way every text field does.
fn onLineDoubleClick(ctx: ?*anyopaque) void {
    const lc: *LineClick = @ptrCast(@alignCast(ctx.?));
    const self = lc.app;
    const at = lineOffsetAtPointer(self, lc.line) orelse return;
    editor.selectWordAt(&self.ed, at);
    self.focus = .sql_editor;
}

pub fn editorLine(self: *App, line: usize, has_caret: bool) void {
    const start = self.ed.lineStartAt(line);
    var end = start;
    while (end < self.ed.len and self.ed.buf[end] != '\n') end += 1;
    const text = self.ed.buf[start..end];

    const caret_at: ?usize = if (has_caret and self.ed.caret.offset >= start and
        self.ed.caret.offset <= end)
        self.ed.caret.offset - start
    else
        null;

    // A selection is drawn as a highlighted run, the same way the small fields draw one.
    if (self.ed.caret.selection()) |span| {
        const a = @max(span.start, start);
        const b = @min(span.end, end);
        if (a < b) {
            const s0 = a - start;
            const s1 = b - start;
            if (s0 > 0) text_mod.label(.{ .str = text[0..s0], .font_size = theme.font_size, .color = theme.text });
            box_mod.box(.{
                .id = self.cellId("editor.sel", line),
                .w = .fit,
                .h = .grow,
                .direction = .row,
                .bg = theme.bg_selected,
            }, self, noChildren);
            text_mod.label(.{ .str = text[s0..s1], .font_size = theme.font_size, .color = theme.text_bright });
            if (s1 < text.len) text_mod.label(.{ .str = text[s1..], .font_size = theme.font_size, .color = theme.text });
            return;
        }
    }

    text_mod.label(.{
        .str = text,
        .font_size = theme.font_size,
        .color = theme.text,
    });
    if (caret_at) |at| caretBar(self, line, at, text);
}

/// The x of byte `at` in `text`, measured with the font that draws the line — not a guessed cell width.
fn columnX(text: []const u8, at: usize) f32 {
    return ui.text.measureText(text[0..@min(at, text.len)], theme.font_size).w;
}

/// The byte offset in `text` closest to `x`, measured the same way the line is drawn.
fn offsetAtX(text: []const u8, x: f32) usize {
    if (text.len == 0 or x <= 0) return 0;
    var lo: usize = 0;
    var hi: usize = text.len;
    // Largest offset whose prefix still ends left of x.
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (columnX(text, mid) <= x) lo = mid else hi = mid - 1;
    }
    // Never leave the caret inside a codepoint.
    while (lo > 0 and lo < text.len and (text[lo] & 0xC0) == 0x80) lo -= 1;
    // The nearer edge wins, which is what makes a click between two letters feel right.
    if (lo < text.len) {
        const step = editor.codepointLen(text, lo);
        if (x - columnX(text, lo) > columnX(text, lo + step) - x) return lo + step;
    }
    return lo;
}

/// The caret: a 1px bar floated over the line at the caret's column.
///
/// It is NOT a `|` inserted into the text. A glyph takes a character cell, so the tail of the line shifted every time
/// the caret blinked, and it sat on the baseline like a letter instead of standing between two of them.
fn caretBar(self: *App, line: usize, at: usize, text: []const u8) void {
    cl.UI()(.{
        .id = .ID(self.cellId("editor.caret", line)),
        .layout = .{ .sizing = .{ .w = .fixed(1), .h = .fixed(@floatFromInt(theme.font_size + 4)) } },
        .floating = .{
            // The font's own advance for the run before the caret: a fixed cell width drifts and overlaps the glyph.
            .offset = .{ .x = columnX(text, at), .y = 1 },
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .z_index = 2,
        },
        // Hidden by going transparent, never by leaving it out: a missing box would reflow the line on every blink.
        .background_color = if (editor.caretVisible(&self.ed)) theme.text_bright.toClay() else .{ 0, 0, 0, 0 },
    })({});
}

fn noChildren(_: *App) void {}

// ---- results --------------------------------------------------------------

fn onRunClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.runEditor();
}
