const std = @import("std");
const ui = @import("glinlandui");
const props = ui.props;
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

pub fn statusBar(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "status" },
        .w = .grow,
        .h = .{ .fixed = theme.status_h },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = props.Pad.all(8),
        .gap = 12,
    }, self, statusBarChildren);
}

pub fn statusBarChildren(self: *App) void {
    text_mod.label(.{
        .label = .{ .text = if (self.db_open) "connected" else "no connection", .size = theme.font_size_tiny, .color = if (self.db_open) theme.ok else theme.text_faint },
    });
    text_mod.label(.{
        .label = .{ .text = if (self.db_open) self.db_path else "—", .size = theme.font_size_tiny, .color = theme.text_faint },
    });
    box_mod.spacer(.{ .text = "status.spacer" });
    text_mod.label(.{ .label = .{ .text = self.status, .size = theme.font_size_tiny, .color = theme.text_dim } });
}

// ---- palette --------------------------------------------------------------
