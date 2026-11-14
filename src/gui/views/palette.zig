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

pub fn paletteBand(self: *App) void {
    box_mod.box(.{
        .id = "palette",
        .w = .grow,
        .h = .{ .fixed = 200 },
        .direction = .column,
        .bg = theme.bg_panel,
        .pad = 10,
        .gap = 6,
    }, self, paletteBandChildren);
}

pub fn paletteBandChildren(self: *App) void {
    input_mod.liveField(.{
        .id = "palette.input",
        .font_size = theme.font_size,
        .fg = theme.text_bright,
        .bg = theme.bg_editor,
        .sel_fg = theme.text_bright,
        .sel_bg = theme.bg_selected,
        .caret_fg = theme.caret,
        .h = 30,
        .pad_tb = 5,
        .pad_lr = 10,
        .border_width = 1,
        .border_color = theme.line,
    }, &self.palette_ctx);

    const matches = self.paletteMatchCount();
    if (matches == 0) {
        text_mod.label(.{ .str = "no match", .font_size = theme.font_size_small, .color = theme.text_faint });
        return;
    }

    const shown = @min(matches, 6);
    for (0..shown) |i| {
        paletteRow(self, i);
    }
}

/// Context for one palette row: which table it opens.
const PaletteCtx = struct { app: *App, table_index: usize };

pub fn paletteRow(self: *App, i: usize) void {
    const table_index = self.paletteMatchAt(i) orelse return;
    const id = self.cellId("palette.row", i);
    const selected = self.palette_idx == i;

    box_mod.box(.{
        .id = id,
        .w = .grow,
        .h = .{ .fixed = 24 },
        .direction = .row,
        .bg = if (selected) theme.bg_selected else theme.bg_panel,
        .radius = 4,
        .pad = 4,
        .gap = 8,
    }, PaletteCtx{ .app = self, .table_index = table_index }, paletteRowChildren);

    registry.registerZCursor(ui.zclay.getElementId(id), onPaletteRowClick, self, table_index, 0, .pointer);
}

pub fn paletteRowChildren(ctx: PaletteCtx) void {
    const self = ctx.app;
    if (ctx.table_index >= self.tables.items.len) return;
    text_mod.label(.{
        .str = self.tables.items[ctx.table_index].name,
        .font_size = theme.font_size_small,
        .color = theme.text,
    });
}

// ---- picker ---------------------------------------------------------------

/// Rows drawn in the listing.
const max_picker_rows: usize = 6;

fn onPaletteRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.closePalette();
    self.openTableTab(index);
}
