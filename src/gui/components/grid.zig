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
const value_mod = @import("meja").value;
const editor = ui.text_editor;

pub fn gridBody(self: *App) void {
    if (!self.has_result) {
        box_mod.box(.{
            .id = .{ .text = "grid.empty" },
            .w = .grow,
            .h = .grow,
            .direction = .column,
            .pad = props.Pad.all(20),
            .gap = 6,
        }, self, gridEmptyChildren);
        return;
    }
    if (self.result.columnCount() == 0) {
        box_mod.box(.{
            .id = .{ .text = "grid.nocols" },
            .w = .grow,
            .h = .grow,
            .direction = .column,
            .pad = props.Pad.all(20),
        }, self, gridNoColsChildren);
        return;
    }

    gridHeader(self);
    scroll_mod.scroll(.{
        .id = .{ .text = "grid.scroll" },
        .direction = .both,
        .w = .{ .clamp = .{ .min = 0, .max = viewportWidth(self), .grow = true } },

        .h = .grow,
        .show_scrollbar = true,
    }, self, gridContent);

    maybeLoadMore(self);
}

/// One fixed-width box holding every row.
fn gridContent(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "grid.content" },
        .w = .{ .fixed = totalWidth(self) },
        .h = .fit,
        .direction = .column,
        .gap = 0,
    }, self, gridContentChildren);
}

fn gridContentChildren(self: *App) void {
    gridRows(self);
}

/// The width the grid may occupy: the window minus the sidebar.
fn viewportWidth(self: *App) f32 {
    const w = @as(f32, @floatFromInt(self.window_w)) - theme.sidebar_width;
    return @max(w, 200);
}

/// The full table width: the row-number gutter plus every column.
pub fn totalWidth(self: *App) f32 {
    var w: f32 = theme.rownum_w;
    for (self.col_widths.items) |cw| w += @floatFromInt(cw);
    return w;
}

pub fn gridColumns(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "grid.columns" },
        .w = .{ .fixed = totalWidth(self) },
        .h = .grow,
        .direction = .column,
        .gap = 0,
    }, self, gridColumnsChildren);
}

pub fn gridColumnsChildren(self: *App) void {
    gridHeader(self);
    scroll_mod.scroll(.{
        .id = .{ .text = "grid.scroll" },
        .direction = .vertical,
        .w = .{ .fixed = totalWidth(self) },
        .h = .grow,
        .show_scrollbar = true,
    }, self, gridRows);
}

/// Ask for the next chunk when the viewport is within a row of the bottom.
pub fn maybeLoadMore(self: *App) void {
    if (!self.has_result or !self.result.truncated) return;
    const v = scroll_mod.view("grid.scroll");
    if (!v.found) return;
    if (v.content_height <= v.height) return;
    if (!self.loader.wantsMore(v.y, v.height, v.content_height, 40)) return;
    self.loadMore();
}

pub fn gridEmptyChildren(self: *App) void {
    _ = self;
    text_mod.label(.{ .label = .{ .text = "Nothing to show yet", .size = theme.font_size, .color = theme.text_dim } });
    text_mod.label(.{
        .label = .{ .text = "Pick a table from the tree, or write a query and press Ctrl+Enter.", .size = theme.font_size_tiny, .color = theme.text_faint },
    });
}

pub fn gridNoColsChildren(self: *App) void {
    text_mod.label(.{ .label = .{ .text = self.status, .size = theme.font_size_small, .color = theme.text_dim } });
}

pub fn gridHeader(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "grid.header" },
        .w = .{ .clamp = .{ .min = 0, .max = viewportWidth(self), .grow = true } },

        .h = .{ .fixed = @floatFromInt(theme.header_height) },
        .direction = .row,
        .bg = theme.bg_header,
        .gap = 0,
        .border = .{ .width = 1, .color = theme.line },
    }, self, gridHeaderChildren);
}

pub fn gridHeaderChildren(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "grid.header.num" },
        .w = .{ .fixed = theme.rownum_w },
        .h = .grow,
        .direction = .row,
        .pad = props.Pad.axes(0, theme.cell_padding),
    }, self, headerNumChildren);

    // The header is outside the scroll container, so it follows the body's horizontal offset by hand.
    const sx: f32 = scroll_mod.view("grid.scroll").x;

    var x: f32 = 0;
    var first: usize = 0;
    while (first < self.col_widths.items.len) : (first += 1) {
        const w: f32 = @floatFromInt(self.col_widths.items[first]);
        if (x + w > sx) break;
        x += w;
    }
    const lead = x - sx;
    if (lead > 0) padBox(self, "grid.head.pad", lead);

    var c: usize = first;
    while (c < self.col_widths.items.len) : (c += 1) {
        headerCell(self, c);
    }
}

pub fn headerNumChildren(self: *App) void {
    _ = self;
    text_mod.label(.{ .label = .{ .text = "#", .size = theme.font_size_tiny, .color = theme.text_ghost } });
}

/// Context for one header cell: which column.
const HeaderCtx = struct { app: *App, col: usize };

pub fn headerCell(self: *App, c: usize) void {
    const width = if (c < self.col_widths.items.len) self.col_widths.items[c] else 120;
    const id = ui.frame.elementId("grid.head", c);

    box_mod.box(.{
        .id = .{ .text = id },
        .w = .{ .fixed = @floatFromInt(width) },
        .h = .grow,
        .direction = .row,
        .pad = props.Pad.axes(0, theme.cell_padding),
        .gap = 6,
    }, HeaderCtx{ .app = self, .col = c }, headerCellChildren);

    registry.registerZCursor(ui.frame.clayId(id), onHeaderClick, self, c, 0, .pointer);
}

pub fn headerCellChildren(ctx: HeaderCtx) void {
    const self = ctx.app;
    const c = ctx.col;
    if (c >= self.result.columns.len) return;
    const col = self.result.columns[c];

    text_mod.label(.{ .label = .{ .text = col.name, .size = theme.font_size_small, .color = theme.text_bright } });

    const type_name = switch (col.storage_class) {
        .integer => "INT",
        .real => "REAL",
        .text => "TEXT",
        .blob => "BLOB",
        .null_value => "NULL",
        .unknown => "?",
    };
    const badge_id = ui.frame.elementId("grid.head.badge", c);
    badge_mod.badge(.{
        .id = .{ .text = badge_id },
        .label = .{ .text = type_name, .size = 9, .color = theme.text_ghost },
        .bg = theme.bg_editor,
        .pad = props.Pad.axes(0, 4),
    });

    if (self.sort_col) |sc| {
        if (sc == c and self.sort_dir != 0) {
            text_mod.label(.{
                .label = .{ .text = if (self.sort_dir > 0) "ASC" else "DESC", .size = 9, .color = theme.accent },
            });
        }
    }
}

pub fn gridRows(self: *App) void {
    const total = self.pageRowCount();
    if (total == 0) return;
    const row_h: f32 = @floatFromInt(theme.row_height);

    // Virtualise: declare only the rows the viewport can see, with spacers above and below so the scrollbar still reflects the whole result.
    var first: usize = 0;
    // A hard cap even before the scroll data exists: the first frame has no scroll offset, and declaring 200 rows x 13 columns exhausts the frame arena, which makes every id fall back to the same string and Clay log duplicate_id for each one.
    var visible: usize = @min(total, 60);
    const v = scroll_mod.view("grid.scroll");
    if (v.found) {
        const scrolled = v.y;
        const view = v.height;
        const first_f: f32 = @floor(scrolled / row_h);
        first = @min(@as(usize, @intFromFloat(first_f)), total -| 1);
        const fits_f: f32 = @ceil(view / row_h) + 2;
        const fits: usize = @intFromFloat(fits_f);
        visible = @min(fits, total - first);
    }

    if (first > 0) padBox(self, "grid.pad.top", @as(f32, @floatFromInt(first)) * row_h);
    for (0..visible) |i| gridRow(self, first + i);
    const after = total - (first + visible);
    if (after > 0) padBox(self, "grid.pad.bottom", @as(f32, @floatFromInt(after)) * row_h);
}

/// A transparent box of a fixed height, used to stand in for rows that are scrolled out of view.
pub fn padBox(self: *App, id: []const u8, height: f32) void {
    box_mod.box(.{
        .id = .{ .text = id },
        .w = .grow,
        .h = .{ .fixed = height },
        .direction = .row,
    }, self, noChildren);
}

/// Context for one grid row: which display position on the page.
const RowCtx = struct { app: *App, display: usize };

pub fn gridRow(self: *App, display_index: usize) void {
    const id = ui.frame.elementId("grid.row", display_index);

    box_mod.box(.{
        .id = .{ .text = id },
        .w = .{ .fixed = totalWidth(self) },
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .bg = if (display_index % 2 == 0) theme.bg_row_even else theme.bg_row_odd,
        .gap = 0,
    }, RowCtx{ .app = self, .display = display_index }, gridRowChildren);
}

pub fn gridRowChildren(ctx: RowCtx) void {
    const self = ctx.app;
    const row_index = self.pageRowAt(ctx.display) orelse return;
    if (row_index >= self.result.rows.len) return;
    const row = self.result.rows[row_index];

    // Row number: the display position, so a filtered view still counts 1..n.
    box_mod.box(.{
        .id = .{ .text = ui.frame.elementId("grid.num", ctx.display) },
        .w = .{ .fixed = theme.rownum_w },
        .h = .grow,
        .direction = .row,
        .pad = props.Pad.axes(0, theme.cell_padding),
    }, ctx, rowNumChildren);

    var c: usize = 0;
    while (c < self.col_widths.items.len) : (c += 1) {
        if (c >= row.values.len) break;
        cell(self, ctx.display, c);
    }
}

pub fn rowNumChildren(ctx: RowCtx) void {
    const shown = ui.frame.formatText("{d}", .{ctx.display + 1});
    text_mod.label(.{ .label = .{ .text = shown, .size = theme.font_size_tiny, .color = theme.text_ghost } });
}

/// Context for one grid cell: which row on the page, which column.
const CellCtx = struct { app: *App, display: usize, col: usize };

pub fn cell(self: *App, display_index: usize, c: usize) void {
    const width = if (c < self.col_widths.items.len) self.col_widths.items[c] else 120;

    box_mod.box(.{
        .id = .{ .text = ui.frame.elementId2("grid.cell", display_index, c) },
        .w = .{ .fixed = @floatFromInt(width) },
        .h = .grow,
        .direction = .row,
        .pad = props.Pad.axes(0, theme.cell_padding),
    }, CellCtx{ .app = self, .display = display_index, .col = c }, cellChildren);
}

pub fn cellChildren(ctx: CellCtx) void {
    const self = ctx.app;
    const row_index = self.pageRowAt(ctx.display) orelse return;
    if (row_index >= self.result.rows.len) return;
    const row = self.result.rows[row_index];
    if (ctx.col >= row.values.len) return;

    const v = row.values[ctx.col];
    const is_null = v.isNull();
    // NOT a local buffer: the draw command keeps this pointer until the rasteriser runs. Claim what the value needs, not a fixed 512: a wide grid would exhaust the frame arena and every id would fall back to the same string.
    const buf = ui.frame.claimText(256);
    const shown = if (is_null) "NULL" else value_mod.render(buf, v);

    text_mod.label(.{
        .label = .{ .text = shown, .size = theme.font_size_small, .color = if (is_null) theme.text_null_value else theme.text },
    });
}

pub fn gridFooter(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "pager" },
        .w = .grow,
        .h = .{ .fixed = theme.status_h },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = props.Pad.axes(0, theme.cell_padding),
        .gap = 8,
    }, self, gridFooterChildren);
}

pub fn gridFooterChildren(self: *App) void {
    const total = self.row_order.items.len;
    const shown = ui.frame.formatText("{d} rows loaded", .{total});
    text_mod.label(.{ .label = .{ .text = shown, .size = theme.font_size_tiny, .color = theme.text_dim } });

    box_mod.spacer(.{ .text = "pager.spacer" });

    if (self.has_result and self.result.truncated) {
        text_mod.label(.{
            .label = .{ .text = "scroll for more", .size = theme.font_size_tiny, .color = theme.text_faint },
        });
    } else if (self.has_result) {
        text_mod.label(.{
            .label = .{ .text = "end of result", .size = theme.font_size_tiny, .color = theme.text_ghost },
        });
    }
}

fn noChildren(_: *App) void {}

fn onHeaderClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.setSort(index);
}
