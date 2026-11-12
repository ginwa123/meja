//! meja — the desktop database browser.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

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

const meja = @import("meja");
const query = meja.query;
const value_mod = meja.value;
const schema = meja.schema;
const sql = meja.sql;

const app_mod = @import("app.zig");
const App = app_mod.App;
const editor = @import("editor.zig");
const grid = @import("grid.zig");
const picker_mod = @import("picker.zig");
const dialog = @import("dialog.zig");
const theme = @import("theme.zig");

// ---- shell ----------------------------------------------------------------

pub fn App_root(ctx: ?*anyopaque, w: u32, h: u32) void {
    root(ctx, w, h);
}

pub fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.window_w = w;
    self.window_h = h;
    // Every label below borrows from this arena, so it resets once, here, before anything claims space.
    self.beginFrame();
    // The tree's labels and counts live in the same arena, so it is rebuilt inside the frame.
    self.rebuildTree();
    self.rebuildTabViews();

    box_mod.box(.{
        .id = "root",
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_app,
        .gap = 0,
    }, self, rootChildren);
}

fn rootChildren(self: *App) void {
    topBar(self);
    if (self.palette_open) paletteBand(self);
    if (self.picker.open) pickerPane(self);
    mainRow(self);
    statusBar(self);
}

// ---- top bar --------------------------------------------------------------

fn topBar(self: *App) void {
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

fn topBarChildren(self: *App) void {
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

fn brand(self: *App) void {
    box_mod.box(.{
        .id = "brand",
        .w = .fit,
        .h = .grow,
        .direction = .row,
        .gap = 8,
    }, self, brandChildren);
}

fn brandChildren(self: *App) void {
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

fn brandMarkChildren(self: *App) void {
    _ = self;
    text_mod.label(.{ .str = "m", .font_size = theme.font_size_tiny, .color = theme.accent });
}

fn connChip(self: *App) void {
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

fn connChipChildren(self: *App) void {
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

fn noChildren(_: *App) void {}

// ---- main row -------------------------------------------------------------

fn mainRow(self: *App) void {
    box_mod.box(.{
        .id = "main",
        .w = .grow,
        .h = .grow,
        .direction = .row,
        .gap = 0,
    }, self, mainRowChildren);
}

fn mainRowChildren(self: *App) void {
    sidebar(self);
    work(self);
}

// ---- sidebar --------------------------------------------------------------

fn sidebar(self: *App) void {
    box_mod.box(.{
        .id = "sidebar",
        .w = .{ .fixed = theme.sidebar_width },
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_panel,
        .pad = 8,
        .gap = 6,
    }, self, sidebarChildren);
}

fn sidebarChildren(self: *App) void {
    treeSearchField(self);

    scroll_mod.scroll(.{
        .id = "sidebar.scroll",
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .show_scrollbar = true,
    }, self, sidebarTree);

    sidebarFooter(self);
}

fn treeSearchField(self: *App) void {
    input_mod.fieldEdit(.{
        .id = "sidebar.search",
        .font_size = theme.font_size_small,
        .fg = theme.text,
        .bg = theme.bg_editor,
        .sel_fg = theme.bg_selected,
        .h = 28,
        .pad_tb = 4,
        .pad_lr = 8,
        .border_width = 1,
        .border_color = theme.line,
    }, self.tree_search_ed.text(), .{
        .caret = @min(self.tree_search_ed.caret.offset, self.tree_search_ed.len),
        .anchor = self.tree_search_ed.caret.anchor,
    });
}

fn sidebarTree(self: *App) void {
    tree_mod.tree(.{
        .id = "sidebar.tree",
        .rows = self.tree_rows.items,
        .row_h = theme.tree_row_height,
        .indent = 13,
        .pad_lr = 6,
        .row_bg = theme.bg_panel,
        .selected_bg = theme.bg_selected,
        .hover_bg = theme.bg_header,
        .fg = theme.text,
        .selected_fg = theme.text_bright,
        .group_fg = theme.text_bright,
        .meta_fg = theme.text_faint,
        .caret_fg = theme.text_faint,
        .on_select = onTreeRowClick,
        .ctx = self,
    });
}

fn sidebarFooter(self: *App) void {
    box_mod.box(.{
        .id = "sidebar.foot",
        .w = .grow,
        .h = .{ .fixed = 28 },
        .direction = .row,
        .gap = 6,
    }, self, sidebarFooterChildren);
}

fn sidebarFooterChildren(self: *App) void {
    button.button(.{
        .id = "sidebar.open",
        .label = "Connect…",
        .font_size = theme.font_size_tiny,
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .pad_tb = 3,
        .pad_lr = 8,
        .on_click = onSidebarOpenClick,
        .ctx = self,
    });
    button.button(.{
        .id = "sidebar.browse",
        .label = "Browse…",
        .font_size = theme.font_size_tiny,
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .pad_tb = 3,
        .pad_lr = 8,
        .on_click = onSidebarBrowseClick,
        .ctx = self,
    });
    button.button(.{
        .id = "sidebar.newquery",
        .label = "New query",
        .font_size = theme.font_size_tiny,
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .pad_tb = 3,
        .pad_lr = 8,
        .on_click = onNewQueryClick,
        .ctx = self,
    });
}

// ---- work -----------------------------------------------------------------

fn work(self: *App) void {
    box_mod.box(.{
        .id = "work",
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .gap = 0,
    }, self, workChildren);
}

fn workChildren(self: *App) void {
    tabBar(self);
    editorPane(self);
    resultsPane(self);
}

fn tabBar(self: *App) void {
    if (self.tabs.items.len == 0) {
        box_mod.box(.{
            .id = "tabs.empty",
            .w = .grow,
            .h = .{ .fixed = theme.tabs_h },
            .direction = .row,
            .bg = theme.bg_panel,
            .pad = 8,
        }, self, tabsEmptyChildren);
        return;
    }

    tabs_mod.tabs(.{
        .id = "tabs",
        .tabs = self.tab_views.items,
        .h = @intFromFloat(theme.tabs_h),
        .bg = theme.bg_tab,
        .active_bg = theme.bg_tab_active,
        .fg = theme.text_dim,
        .active_fg = theme.text_bright,
        .close_fg = theme.text_faint,
        .on_select = onTabSelect,
        .on_close = onTabClose,
        .ctx = self,
    });
}

fn tabsEmptyChildren(self: *App) void {
    _ = self;
    text_mod.label(.{
        .str = "no tabs — pick a table from the tree",
        .font_size = theme.font_size_tiny,
        .color = theme.text_faint,
    });
}

fn editorPane(self: *App) void {
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

fn editorPaneChildren(self: *App) void {
    editorBar(self);
    editorBody(self);
}

fn editorBar(self: *App) void {
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

fn editorBarChildren(self: *App) void {
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

fn editorBody(self: *App) void {
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

fn editorBodyChildren(self: *App) void {
    const line_count = @max(self.ed.lineCount(), 1);
    const caret_line = self.ed.lineNumber(self.ed.caret.offset);
    for (0..line_count) |line| {
        editorLine(self, line, line == caret_line);
    }
}

/// Longest editor line drawn in one piece.
const max_line_bytes: usize = 1024;

fn editorLine(self: *App, line: usize, has_caret: bool) void {
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

fn resultsPane(self: *App) void {
    box_mod.box(.{
        .id = "results",
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_app,
        .gap = 0,
    }, self, resultsPaneChildren);
}

fn resultsPaneChildren(self: *App) void {
    resultsBar(self);
    gridBody(self);
    pager(self);
}

fn resultsBar(self: *App) void {
    box_mod.box(.{
        .id = "results.bar",
        .w = .grow,
        .h = .{ .fixed = theme.bar_h },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = 6,
        .gap = 10,
    }, self, resultsBarChildren);
}

fn resultsBarChildren(self: *App) void {
    resultsStats(self);
    box_mod.spacer("results.bar.spacer");
    filterField(self);
}

fn resultsStats(self: *App) void {
    if (!self.has_result) {
        text_mod.label(.{ .str = "no results", .font_size = theme.font_size_tiny, .color = theme.text_faint });
        return;
    }
    const buf = self.claimText(96);
    const shown = std.fmt.bufPrint(buf, "{d} rows x {d} cols", .{
        self.row_order.items.len,
        self.result.columnCount(),
    }) catch buf[0..0];
    text_mod.label(.{ .str = shown, .font_size = theme.font_size_tiny, .color = theme.text_dim });

    const ms_buf = self.claimText(32);
    const ms_text = std.fmt.bufPrint(ms_buf, "{d} ms", .{
        self.result.elapsed_ns / 1_000_000,
    }) catch ms_buf[0..0];
    text_mod.label(.{ .str = ms_text, .font_size = theme.font_size_tiny, .color = theme.text_faint });
    if (self.filter.len > 0) {
        text_mod.label(.{ .str = "filtered", .font_size = theme.font_size_tiny, .color = theme.warn });
    }
}

fn filterField(self: *App) void {
    input_mod.fieldEdit(.{
        .id = "results.filter",
        .font_size = theme.font_size_tiny,
        .fg = theme.text,
        .bg = theme.bg_editor,
        .sel_fg = theme.bg_selected,
        .w = 180,
        .h = 22,
        .pad_tb = 2,
        .pad_lr = 8,
        .border_width = 1,
        .border_color = theme.line,
    }, self.filter_ed.text(), .{
        .caret = @min(self.filter_ed.caret.offset, self.filter_ed.len),
        .anchor = self.filter_ed.caret.anchor,
    });
}

fn gridBody(self: *App) void {
    if (!self.has_result) {
        box_mod.box(.{
            .id = "grid.empty",
            .w = .grow,
            .h = .grow,
            .direction = .column,
            .pad = 20,
            .gap = 6,
        }, self, gridEmptyChildren);
        return;
    }
    if (self.result.columnCount() == 0) {
        box_mod.box(.{
            .id = "grid.nocols",
            .w = .grow,
            .h = .grow,
            .direction = .column,
            .pad = 20,
        }, self, gridNoColsChildren);
        return;
    }

    gridHeader(self);

    scroll_mod.scroll(.{
        .id = "grid.scroll",
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .show_scrollbar = true,
    }, self, gridRows);
}

fn gridEmptyChildren(self: *App) void {
    _ = self;
    text_mod.label(.{ .str = "Nothing to show yet", .font_size = theme.font_size, .color = theme.text_dim });
    text_mod.label(.{
        .str = "Pick a table from the tree, or write a query and press Ctrl+Enter.",
        .font_size = theme.font_size_tiny,
        .color = theme.text_faint,
    });
}

fn gridNoColsChildren(self: *App) void {
    text_mod.label(.{ .str = self.status, .font_size = theme.font_size_small, .color = theme.text_dim });
}

fn gridHeader(self: *App) void {
    box_mod.box(.{
        .id = "grid.header",
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .bg = theme.bg_header,
        .gap = 0,
    }, self, gridHeaderChildren);
}

fn gridHeaderChildren(self: *App) void {
    box_mod.box(.{
        .id = "grid.header.num",
        .w = .{ .fixed = theme.rownum_w },
        .h = .grow,
        .direction = .row,
        .pad = 4,
    }, self, headerNumChildren);

    const cols = grid.visibleColumns(self.col_widths.items, @floatFromInt(self.window_w), 0);
    var c: usize = cols.first;
    while (c < cols.first + cols.count) : (c += 1) {
        headerCell(self, c);
    }
}

fn headerNumChildren(self: *App) void {
    _ = self;
    text_mod.label(.{ .str = "#", .font_size = theme.font_size_tiny, .color = theme.text_ghost });
}

/// Context for one header cell: which column.
const HeaderCtx = struct { app: *App, col: usize };

fn headerCell(self: *App, c: usize) void {
    const width = if (c < self.col_widths.items.len) self.col_widths.items[c] else 120;
    const id = self.cellId("grid.head", c);

    box_mod.box(.{
        .id = id,
        .w = .{ .fixed = @floatFromInt(width) },
        .h = .grow,
        .direction = .row,
        .pad = 4,
        .gap = 6,
    }, HeaderCtx{ .app = self, .col = c }, headerCellChildren);

    registry.registerZCursor(ui.zclay.getElementId(id), onHeaderClick, self, c, 0, .pointer);
}

fn headerCellChildren(ctx: HeaderCtx) void {
    const self = ctx.app;
    const c = ctx.col;
    if (c >= self.result.columns.len) return;
    const col = self.result.columns[c];

    text_mod.label(.{ .str = col.name, .font_size = theme.font_size_small, .color = theme.text_bright });

    const type_name = switch (col.storage_class) {
        .integer => "INT",
        .real => "REAL",
        .text => "TEXT",
        .blob => "BLOB",
        .null_value => "NULL",
        .unknown => "?",
    };
    const badge_id = self.cellId("grid.head.badge", c);
    badge_mod.badge(.{
        .id = badge_id,
        .label = type_name,
        .bg = theme.bg_editor,
        .fg = theme.text_ghost,
        .font_size = 9,
        .pad_tb = 0,
        .pad_lr = 4,
    });

    if (self.sort_col) |sc| {
        if (sc == c and self.sort_dir != 0) {
            text_mod.label(.{
                .str = if (self.sort_dir > 0) "ASC" else "DESC",
                .font_size = 9,
                .color = theme.accent,
            });
        }
    }
}

fn gridRows(self: *App) void {
    const count = self.pageRowCount();
    for (0..count) |i| {
        gridRow(self, i);
    }
}

/// Context for one grid row: which display position on the page.
const RowCtx = struct { app: *App, display: usize };

fn gridRow(self: *App, display_index: usize) void {
    const id = self.cellId("grid.row", display_index);

    box_mod.box(.{
        .id = id,
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .bg = if (display_index % 2 == 0) theme.bg_row_even else theme.bg_row_odd,
        .gap = 0,
    }, RowCtx{ .app = self, .display = display_index }, gridRowChildren);
}

fn gridRowChildren(ctx: RowCtx) void {
    const self = ctx.app;
    const row_index = self.pageRowAt(ctx.display) orelse return;
    if (row_index >= self.result.rows.len) return;
    const row = self.result.rows[row_index];

    // Row number: the display position, so a filtered view still counts 1..n.
    box_mod.box(.{
        .id = self.cellId("grid.num", ctx.display),
        .w = .{ .fixed = theme.rownum_w },
        .h = .grow,
        .direction = .row,
        .pad = 4,
    }, ctx, rowNumChildren);

    const cols = grid.visibleColumns(self.col_widths.items, @floatFromInt(self.window_w), 0);
    var c: usize = cols.first;
    while (c < cols.first + cols.count) : (c += 1) {
        if (c >= row.values.len) break;
        cell(self, ctx.display, c);
    }
}

fn rowNumChildren(ctx: RowCtx) void {
    const self = ctx.app;
    const buf = self.claimText(16);
    const shown = std.fmt.bufPrint(buf, "{d}", .{ctx.display + 1}) catch buf[0..0];
    text_mod.label(.{ .str = shown, .font_size = theme.font_size_tiny, .color = theme.text_ghost });
}

/// Context for one grid cell: which row on the page, which column.
const CellCtx = struct { app: *App, display: usize, col: usize };

fn cell(self: *App, display_index: usize, c: usize) void {
    const width = if (c < self.col_widths.items.len) self.col_widths.items[c] else 120;

    box_mod.box(.{
        .id = self.cellId2("grid.cell", display_index, c),
        .w = .{ .fixed = @floatFromInt(width) },
        .h = .grow,
        .direction = .row,
        .pad = 4,
    }, CellCtx{ .app = self, .display = display_index, .col = c }, cellChildren);
}

fn cellChildren(ctx: CellCtx) void {
    const self = ctx.app;
    const row_index = self.pageRowAt(ctx.display) orelse return;
    if (row_index >= self.result.rows.len) return;
    const row = self.result.rows[row_index];
    if (ctx.col >= row.values.len) return;

    const v = row.values[ctx.col];
    const is_null = v.isNull();
    // NOT a local buffer: the draw command keeps this pointer until the rasteriser runs.
    const buf = self.claimText(512);
    const shown = if (is_null) "NULL" else value_mod.render(buf, v);

    text_mod.label(.{
        .str = shown,
        .font_size = theme.font_size_small,
        .color = if (is_null) theme.text_null_value else theme.text,
    });
}

fn pager(self: *App) void {
    box_mod.box(.{
        .id = "pager",
        .w = .grow,
        .h = .{ .fixed = 28 },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = 6,
        .gap = 8,
    }, self, pagerChildren);
}

fn pagerChildren(self: *App) void {
    const total = self.row_order.items.len;
    const start = self.page * App.page_size;
    const end = @min(start + App.page_size, total);

    const buf = self.claimText(96);
    const shown = if (total == 0)
        std.fmt.bufPrint(buf, "0 rows", .{}) catch buf[0..0]
    else
        std.fmt.bufPrint(buf, "{d}–{d} of {d}", .{ start + 1, end, total }) catch buf[0..0];
    text_mod.label(.{ .str = shown, .font_size = theme.font_size_tiny, .color = theme.text_dim });

    box_mod.spacer("pager.spacer");

    button.button(.{
        .id = "pager.prev",
        .label = "Prev",
        .font_size = theme.font_size_tiny,
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .pad_tb = 2,
        .pad_lr = 8,
        .disabled = self.page == 0,
        .on_click = onPrevPage,
        .ctx = self,
    });

    const page_buf = self.claimText(48);
    const page_text = std.fmt.bufPrint(page_buf, "page {d} / {d}", .{
        self.page + 1,
        self.pageCount(),
    }) catch page_buf[0..0];
    text_mod.label(.{ .str = page_text, .font_size = theme.font_size_tiny, .color = theme.text_faint });

    button.button(.{
        .id = "pager.next",
        .label = "Next",
        .font_size = theme.font_size_tiny,
        .bg = theme.bg_header,
        .fg = theme.text_dim,
        .hover_bg = theme.bg_hover,
        .pad_tb = 2,
        .pad_lr = 8,
        .disabled = self.page + 1 >= self.pageCount(),
        .on_click = onNextPage,
        .ctx = self,
    });
}

// ---- status ---------------------------------------------------------------

fn statusBar(self: *App) void {
    box_mod.box(.{
        .id = "status",
        .w = .grow,
        .h = .{ .fixed = theme.status_h },
        .direction = .row,
        .bg = theme.bg_panel,
        .pad = 8,
        .gap = 12,
    }, self, statusBarChildren);
}

fn statusBarChildren(self: *App) void {
    text_mod.label(.{
        .str = if (self.db_open) "connected" else "no connection",
        .font_size = theme.font_size_tiny,
        .color = if (self.db_open) theme.ok else theme.text_faint,
    });
    text_mod.label(.{
        .str = if (self.db_open) self.db_path else "—",
        .font_size = theme.font_size_tiny,
        .color = theme.text_faint,
    });
    box_mod.spacer("status.spacer");
    text_mod.label(.{ .str = self.status, .font_size = theme.font_size_tiny, .color = theme.text_dim });
}

// ---- palette --------------------------------------------------------------

fn paletteBand(self: *App) void {
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

fn paletteBandChildren(self: *App) void {
    input_mod.fieldEdit(.{
        .id = "palette.input",
        .font_size = theme.font_size,
        .fg = theme.text_bright,
        .bg = theme.bg_editor,
        .sel_fg = theme.bg_selected,
        .h = 30,
        .pad_tb = 5,
        .pad_lr = 10,
        .border_width = 1,
        .border_color = theme.line,
    }, self.palette_ed.text(), .{
        .caret = @min(self.palette_ed.caret.offset, self.palette_ed.len),
        .anchor = self.palette_ed.caret.anchor,
    });

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

fn paletteRow(self: *App, i: usize) void {
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

fn paletteRowChildren(ctx: PaletteCtx) void {
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

fn pickerPane(self: *App) void {
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

fn pickerPaneChildren(self: *App) void {
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

fn pickerHeadChildren(self: *App) void {
    text_mod.label(.{ .str = "Open database", .font_size = theme.font_size_small, .color = theme.text_bright });
    text_mod.label(.{ .str = self.picker.dir(), .font_size = theme.font_size_small, .color = theme.text_dim });
}

fn pickerBarChildren(self: *App) void {
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

fn pickerRow(app: *App, index: usize) void {
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

fn pickerRowChildren(ctx: PickerRowCtx) void {
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

fn onPickerRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.activateCandidate(index);
}

fn onOpenButtonClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.openTypedPath();
}

fn onPickerBrowseClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseForDatabase();
}

fn onCancelButtonClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.closePicker();
}

fn onSidebarBrowseClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseForDatabase();
}

// ---- click handlers -------------------------------------------------------

fn onTreeRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.onTreeSelect(index);
}

fn onTabSelect(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.switchTab(index);
}

fn onTabClose(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.closeTab(index);
}

fn onHeaderClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.setSort(index);
}

fn onPaletteRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.closePalette();
    self.openTableTab(index);
}

fn onPaletteClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.palette_open) self.closePalette() else self.openPalette();
}

fn onRunClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.runEditor();
}

fn onPrevPage(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.page > 0) self.setPage(self.page - 1);
}

fn onNextPage(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.setPage(self.page + 1);
}

fn onSidebarOpenClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.picker.open) self.closePicker() else self.openPicker();
}

fn onNewQueryClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.ed.setText("SELECT * FROM ");
    self.runEditor();
}

// ---- entry point ----------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = ui.platform.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var app: App = undefined;
    app.init(gpa, threaded.io());
    defer {
        app.clearResult();
        app.freeTables();
        app.freeTabs();
        if (app.db_open) app.db.deinit();
    }

    // Open whatever the user named.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1) {
        app.open(argv[1]);
    } else {
        // In-memory rather than an error, so the window is never dead on arrival.
        app.open(":memory:");
        app.setStatus("no database open — Ctrl+O to choose one", .{});
    }
    app.openFirstTable();

    var host = try ui.host.Host.init(gpa, &app, App_root_wrapper);
    defer host.deinit();
    host.keys.register(App_key_wrapper, &app);

    var window = ui.Window.init(gpa, .{
        .app_id = "meja",
        .title = "meja",
        .width = 1200,
        .height = 800,
        .min_width = 640,
        .min_height = 400,
    });
    window.delegate = host.delegate();
    try window.run();
}

fn App_root_wrapper(ctx: ?*anyopaque, w: u32, h: u32) void {
    root(ctx, w, h);
}

/// Adapter between the app's key handler and the window delegate.
fn App_key_wrapper(ctx: ?*anyopaque, mods: input_mod.Mods, keycode: u32) bool {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    _ = self.onKey(mods, keycode);
    return ui.keyToClose(keycode);
}

test {
    _ = editor;
    _ = grid;
    _ = picker_mod;
    _ = theme;
    _ = dialog;
    _ = @import("e2e_test.zig");
}
