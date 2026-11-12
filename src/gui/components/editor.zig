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

const app_mod = @import("../app.zig");
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
    const caret_line = self.ed.lineNumber(self.ed.caret.offset);
    for (0..line_count) |line| {
        editorLine(self, line, line == caret_line);
    }
}

/// Longest editor line drawn in one piece.
const max_line_bytes: usize = 1024;

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

    // NOT a local buffer: the draw command keeps this pointer until the rasteriser runs.
    const cap = @min(text.len + 1, max_line_bytes);
    const buf = self.claimText(cap);
    const shown = editor.renderLineWithCaret(text, caret_at, buf);

    text_mod.label(.{
        .str = shown,
        .font_size = theme.font_size,
        .color = theme.text,
    });
}

// ---- results --------------------------------------------------------------

fn onRunClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.runEditor();
}
