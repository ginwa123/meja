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

/// Rows drawn in the listing.
const max_picker_rows: usize = 6;

pub fn pickerPane(self: *App) void {
    const rows = @min(self.picker.entries.items.len, max_picker_rows);
    const height = 64 +
        @as(f32, @floatFromInt(rows)) * @as(f32, @floatFromInt(theme.row_height)) +
        8;

    box_mod.box(.{
        .id = .{ .text = "picker" },
        .w = .grow,
        .h = .{ .fixed = height },
        .direction = .column,
        .bg = theme.bg_header,
        .pad = props.Pad.all(8),
        .gap = 6,
    }, self, pickerPaneChildren);
}

pub fn pickerPaneChildren(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "picker.head" },
        .w = .grow,
        .h = .{ .fixed = 18 },
        .direction = .row,
        .gap = 8,
    }, self, pickerHeadChildren);

    box_mod.box(.{
        .id = .{ .text = "picker.bar" },
        .w = .grow,
        .h = .{ .fixed = 30 },
        .direction = .row,
        .gap = 8,
    }, self, pickerBarChildren);

    if (self.picker.error_message) |err| {
        const shown = ui.frame.formatText("cannot read directory: {s}", .{err});
        text_mod.label(.{ .label = .{ .text = shown, .size = theme.font_size_small, .color = theme.danger } });
        return;
    }

    if (self.picker.entries.items.len == 0) {
        text_mod.label(.{
            .label = .{ .text = "no databases here — type a path above", .size = theme.font_size_small, .color = theme.text_faint },
        });
        return;
    }

    const count = @min(self.picker.entries.items.len, max_picker_rows);
    for (0..count) |i| pickerRow(self, i);
}

pub fn pickerHeadChildren(self: *App) void {
    text_mod.label(.{ .label = .{ .text = "Open database", .size = theme.font_size_small, .color = theme.text_bright } });
    text_mod.label(.{ .label = .{ .text = self.picker.dir(), .size = theme.font_size_small, .color = theme.text_dim } });
}

pub fn pickerBarChildren(self: *App) void {
    input_mod.TextField(&self.picker.field);

    button.button(.{
        .id = .{ .text = "picker.open" },
        .label = .{ .text = "Open", .size = theme.font_size },
        .bg = theme.bg_selected,
        .pad = props.Pad.axes(5, 14),
        .on_click = onOpenButtonClick,
        .ctx = self,
    });
    button.button(.{
        .id = .{ .text = "picker.browse" },
        .label = .{ .text = "Browse…", .size = theme.font_size },
        .bg = theme.bg_header,
        .pad = props.Pad.axes(5, 14),
        .on_click = onPickerBrowseClick,
        .ctx = self,
    });
    button.button(.{
        .id = .{ .text = "picker.cancel" },
        .label = .{ .text = "Cancel", .size = theme.font_size },
        .pad = props.Pad.axes(5, 14),
        .on_click = onCancelButtonClick,
        .ctx = self,
    });
}

/// Context for one listing row: which row, in which picker.
const PickerRowCtx = struct {
    app: *App,
    index: usize,
};

pub fn pickerRow(app: *App, index: usize) void {
    const ctx = PickerRowCtx{ .app = app, .index = index };
    const selected = app.picker.cursor == index;
    const id = ui.frame.elementId("picker.row", index);

    box_mod.box(.{
        .id = .{ .text = id },
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .gap = 6,
        .pad = props.Pad.all(2),
        .bg = if (selected) theme.bg_selected else theme.bg_header,
        .radius = props.Radius.all(3),
    }, ctx, pickerRowChildren);

    registry.registerZCursor(ui.frame.clayId(id), onPickerRowClick, app, index, 0, .pointer);
}

pub fn pickerRowChildren(ctx: PickerRowCtx) void {
    const self = ctx.app;
    if (ctx.index >= self.picker.entries.items.len) return;
    const entry = self.picker.entries.items[ctx.index];
    const selected = self.picker.cursor == ctx.index;

    // A trailing slash is the only marker a directory needs, and it is one the eye reads without a legend.
    text_mod.label(.{
        .label = .{ .text = if (entry.is_dir) "/" else " ", .size = theme.font_size_small, .color = theme.text_faint },
    });
    text_mod.label(.{
        .label = .{ .text = entry.name, .size = theme.font_size_small, .color = if (selected) theme.text_bright else theme.text },
    });
}

pub fn onPickerRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.activateCandidate(index);
}

pub fn onOpenButtonClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.openTypedPath();
}

pub fn onPickerBrowseClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseForDatabase();
}

pub fn onCancelButtonClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.closePicker();
}

pub fn onSidebarBrowseClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseForDatabase();
}
