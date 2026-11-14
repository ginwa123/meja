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

pub fn sidebar(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "sidebar" },
        .w = .{ .fixed = theme.sidebar_width },
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_panel,
        .pad = props.Pad.all(8),
        .gap = 6,
    }, self, sidebarChildren);
}

pub fn sidebarChildren(self: *App) void {
    treeSearchField(self);

    scroll_mod.scroll(.{
        .id = .{ .text = "sidebar.scroll" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .show_scrollbar = true,
    }, self, sidebarTree);

    sidebarFooter(self);
}

pub fn treeSearchField(self: *App) void {
    input_mod.TextField(&self.tree_search_field);
}

pub fn sidebarTree(self: *App) void {
    tree_mod.tree(.{
        .id = .{ .text = "sidebar.tree" },
        .rows = self.tree_rows.items,
        .row_h = theme.tree_row_height,
        .indent = 17,
        .pad_lr = theme.cell_padding,
        .row_bg = theme.bg_panel,
        .selected_bg = theme.bg_selected,
        .hover_bg = theme.bg_header,
        .fg = theme.text,
        .selected_fg = theme.text_bright,
        .group_fg = theme.text_bright,
        .meta_fg = theme.text_faint,
        .caret_fg = theme.text_faint,
        // Selection is a fill AND a 2px bar: colour is never the only cue.
        .selected_bar = theme.accent,
        .on_select = onTreeRowClick,
        .ctx = self,
    });
}

pub fn sidebarFooter(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "sidebar.foot" },
        .w = .grow,
        .h = .{ .fixed = 28 },
        .direction = .row,
        .gap = 6,
    }, self, sidebarFooterChildren);
}

pub fn sidebarFooterChildren(self: *App) void {
    button.button(.{
        .id = .{ .text = "sidebar.open" },
        .label = .{ .text = "Connect…", .size = theme.font_size_tiny },
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .h = .{ .fixed = theme.control_sm_h },
        .radius = props.Radius.all(theme.r_control),
        .pad = props.Pad.axes(0, theme.control_sm_pad_x),
        .on_click = onSidebarOpenClick,
        .ctx = self,
    });
    button.button(.{
        .id = .{ .text = "sidebar.browse" },
        .label = .{ .text = "Browse…", .size = theme.font_size_tiny },
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .h = .{ .fixed = theme.control_sm_h },
        .radius = props.Radius.all(theme.r_control),
        .pad = props.Pad.axes(0, theme.control_sm_pad_x),
        .on_click = onSidebarBrowseClick,
        .ctx = self,
    });
    button.button(.{
        .id = .{ .text = "sidebar.newquery" },
        .label = .{ .text = "New query", .size = theme.font_size_tiny },
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .h = .{ .fixed = theme.control_sm_h },
        .radius = props.Radius.all(theme.r_control),
        .pad = props.Pad.axes(0, theme.control_sm_pad_x),
        .on_click = onNewQueryClick,
        .ctx = self,
    });
}

fn onTreeRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.onTreeSelect(index);
}

fn onSidebarOpenClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.picker.open) self.closePicker() else self.openPicker();
}

fn onSidebarBrowseClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseForDatabase();
}

fn onNewQueryClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.ed.setText("SELECT * FROM ");
    self.runEditor();
}
