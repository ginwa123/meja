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

pub fn topBar(self: *App) void {
    box_mod.box(.{
        .id = "topbar",
        .w = .grow,
        .h = .{ .fixed = theme.topbar_h },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = 10,
        .gap = 10,
    }, self, topBarChildren);
}

pub fn topBarChildren(self: *App) void {
    brand(self);
    connChip(self);
    box_mod.spacer("topbar.spacer");
    button.button(.{
        .id = "topbar.palette",
        .label = "Search tables or run a command   Ctrl+K",
        .font_size = theme.font_size_small,
        .bg = theme.bg_editor,
        .fg = theme.text_faint,
        .hover_bg = theme.bg_header,
        .pad_tb = 5,
        .pad_lr = 12,
        .on_click = onPaletteClick,
        .ctx = self,
    });
}

pub fn brand(self: *App) void {
    box_mod.box(.{
        .id = "brand",
        .w = .fit,
        .h = .grow,
        .direction = .row,
        .gap = 8,
    }, self, brandChildren);
}

pub fn brandChildren(self: *App) void {
    box_mod.box(.{
        .id = "brand.mark",
        .w = .{ .fixed = 20 },
        .h = .{ .fixed = 20 },
        .direction = .row,
        .bg = theme.bg_selected,
        .radius = 5,
    }, self, brandMarkChildren);
    text_mod.label(.{ .str = "meja", .font_size = theme.font_size, .color = theme.text_bright });
}

pub fn brandMarkChildren(self: *App) void {
    _ = self;
    text_mod.label(.{ .str = "m", .font_size = theme.font_size_tiny, .color = theme.accent });
}

pub fn connChip(self: *App) void {
    box_mod.box(.{
        .id = "chip",
        .w = .fit,
        .h = .grow,
        .direction = .row,
        .bg = theme.bg_chip,
        .radius = 6,
        .pad = 6,
        .gap = 7,
    }, self, connChipChildren);
}

pub fn connChipChildren(self: *App) void {
    box_mod.box(.{
        .id = "chip.dot",
        .w = .{ .fixed = 6 },
        .h = .{ .fixed = 6 },
        .direction = .row,
        .bg = if (self.db_open) theme.ok else theme.text_ghost,
        .radius = 3,
    }, self, noChildren);

    text_mod.label(.{
        .str = if (self.db_open) std.fs.path.basename(self.db_path) else "no database",
        .font_size = theme.font_size_small,
        .color = theme.text,
    });
    text_mod.label(.{ .str = "SQLite", .font_size = theme.font_size_tiny, .color = theme.text_faint });
}

pub fn noChildren(_: *App) void {}

fn onPaletteClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.palette_open) self.closePalette() else self.openPalette();
}
