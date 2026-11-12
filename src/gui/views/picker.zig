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

/// Rows drawn in the listing.
const max_picker_rows: usize = 6;

pub fn pickerPane(self: *App) void {
    const rows = @min(self.picker.entries.items.len, max_picker_rows);
    const height = 64 +
        @as(f32, @floatFromInt(rows)) * @as(f32, @floatFromInt(theme.row_height)) +
        8;

    box_mod.box(.{
        .id = "picker",
        .w = .grow,
        .h = .{ .fixed = height },
        .direction = .column,
        .bg = theme.bg_header,
        .pad = 8,
        .gap = 6,
    }, self, pickerPaneChildren);
}

pub fn pickerPaneChildren(self: *App) void {
    box_mod.box(.{
        .id = "picker.head",
        .w = .grow,
        .h = .{ .fixed = 18 },
        .direction = .row,
        .gap = 8,
    }, self, pickerHeadChildren);

    box_mod.box(.{
        .id = "picker.bar",
        .w = .grow,
        .h = .{ .fixed = 30 },
        .direction = .row,
        .gap = 8,
    }, self, pickerBarChildren);

    if (self.picker.error_message) |err| {
        const buf = self.claimText(64);
        const shown = std.fmt.bufPrint(buf, "cannot read directory: {s}", .{err}) catch buf[0..0];
        text_mod.label(.{ .str = shown, .font_size = theme.font_size_small, .color = theme.danger });
        return;
    }

    if (self.picker.entries.items.len == 0) {
        text_mod.label(.{
            .str = "no databases here — type a path above",
            .font_size = theme.font_size_small,
            .color = theme.text_faint,
        });
        return;
    }

    const count = @min(self.picker.entries.items.len, max_picker_rows);
    for (0..count) |i| pickerRow(self, i);
}

pub fn pickerHeadChildren(self: *App) void {
    text_mod.label(.{ .str = "Open database", .font_size = theme.font_size_small, .color = theme.text_bright });
    text_mod.label(.{ .str = self.picker.dir(), .font_size = theme.font_size_small, .color = theme.text_dim });
}

pub fn pickerBarChildren(self: *App) void {
    input_mod.fieldEdit(.{
        .id = "picker.path",
        .font_size = theme.font_size,
        .fg = theme.text,
        .bg = theme.bg_editor,
        .sel_fg = theme.bg_selected,
        .w = 520,
        .h = 30,
        .pad_tb = 4,
        .pad_lr = 8,
    }, self.picker.field.text(), .{
        .caret = @min(self.picker.field.caret.offset, self.picker.field.len),
        .anchor = self.picker.field.caret.anchor,
    });

    button.button(.{
        .id = "picker.open",
        .label = "Open",
        .font_size = theme.font_size,
        .bg = theme.bg_selected,
        .pad_tb = 5,
        .pad_lr = 14,
        .on_click = onOpenButtonClick,
        .ctx = self,
    });
    button.button(.{
        .id = "picker.browse",
        .label = "Browse…",
        .font_size = theme.font_size,
        .bg = theme.bg_header,
        .pad_tb = 5,
        .pad_lr = 14,
        .on_click = onPickerBrowseClick,
        .ctx = self,
    });
    button.button(.{
        .id = "picker.cancel",
        .label = "Cancel",
        .font_size = theme.font_size,
        .pad_tb = 5,
        .pad_lr = 14,
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
    const id = app.cellId("picker.row", index);

    box_mod.box(.{
        .id = id,
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .gap = 6,
        .pad = 2,
        .bg = if (selected) theme.bg_selected else theme.bg_header,
        .radius = 3,
    }, ctx, pickerRowChildren);

    registry.registerZCursor(ui.zclay.getElementId(id), onPickerRowClick, app, index, 0, .pointer);
}

pub fn pickerRowChildren(ctx: PickerRowCtx) void {
    const self = ctx.app;
    if (ctx.index >= self.picker.entries.items.len) return;
    const entry = self.picker.entries.items[ctx.index];
    const selected = self.picker.cursor == ctx.index;

    // A trailing slash is the only marker a directory needs, and it is one the eye reads without a legend.
    text_mod.label(.{
        .str = if (entry.is_dir) "/" else " ",
        .font_size = theme.font_size_small,
        .color = theme.text_faint,
    });
    text_mod.label(.{
        .str = entry.name,
        .font_size = theme.font_size_small,
        .color = if (selected) theme.text_bright else theme.text,
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
