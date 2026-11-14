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
const editor_view = @import("../components/editor.zig");
const grid_view = @import("../components/grid.zig");

pub fn work(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "work" },
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .gap = 0,
    }, self, workChildren);
}

pub fn workChildren(self: *App) void {
    tabBar(self);
    editor_view.editorPane(self);
    resultsPane(self);
}

pub fn tabBar(self: *App) void {
    if (self.tabs.items.len == 0) {
        box_mod.box(.{
            .id = .{ .text = "tabs.empty" },
            .w = .grow,
            .h = .{ .fixed = theme.tabs_h },
            .direction = .row,
            .bg = theme.bg_panel,
            .pad = props.Pad.axes(0, 10),
        }, self, tabsEmptyChildren);
        return;
    }

    tabs_mod.tabs(.{
        .id = .{ .text = "tabs" },
        .tabs = self.tab_views.items,
        .h = @intFromFloat(theme.tabs_h),
        .bg = theme.bg_tab,
        .active_bg = theme.bg_tab_active,
        .fg = theme.text_dim,
        .active_fg = theme.text_bright,
        .close_fg = theme.text_faint,
        .on_select = .{ .f = onTabSelect, .ctx = self },
        .on_close = .{ .f = onTabClose, .ctx = self },
    });
}

pub fn tabsEmptyChildren(self: *App) void {
    _ = self;
    text_mod.label(.{
        .label = .{ .text = "no tabs — pick a table from the tree", .size = theme.font_size_tiny, .color = theme.text_faint },
    });
}

// ---- results --------------------------------------------------------------

pub fn resultsPane(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "results" },
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_app,
        .gap = 0,
    }, self, resultsPaneChildren);
}

pub fn resultsPaneChildren(self: *App) void {
    resultsBar(self);
    grid_view.gridBody(self);
    grid_view.gridFooter(self);
}

pub fn resultsBar(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "results.bar" },
        .w = .grow,
        .h = .{ .fixed = theme.bar_h },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = props.Pad.axes(0, 10),
        .gap = 10,
    }, self, resultsBarChildren);
}

pub fn resultsBarChildren(self: *App) void {
    resultsStats(self);
    box_mod.spacer(.{ .text = "results.bar.spacer" });
    filterField(self);
}

pub fn resultsStats(self: *App) void {
    if (!self.has_result) {
        text_mod.label(.{ .label = .{ .text = "no results", .size = theme.font_size_tiny, .color = theme.text_faint } });
        return;
    }
    const shown = ui.frame.formatText("{d} rows x {d} cols", .{
        self.row_order.items.len,
        self.result.columnCount(),
    });
    text_mod.label(.{ .label = .{ .text = shown, .size = theme.font_size_tiny, .color = theme.text_dim } });

    const ms_text = ui.frame.formatText("{d} ms", .{
        self.result.elapsed_ns / 1_000_000,
    });
    text_mod.label(.{ .label = .{ .text = ms_text, .size = theme.font_size_tiny, .color = theme.text_faint } });
    if (self.filter.len > 0) {
        text_mod.label(.{ .label = .{ .text = "filtered", .size = theme.font_size_tiny, .color = theme.warn } });
    }
}

pub fn filterField(self: *App) void {
    input_mod.textField(&self.filter_field);
}

fn onTabSelect(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.switchTab(index);
}

fn onTabClose(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.closeTab(index);
}
