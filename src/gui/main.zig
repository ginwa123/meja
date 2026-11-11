//! meja — the desktop database browser.
//!
//! Frontend over `meja.core`, drawn with glinlandui. Like the CLI it holds
//! no data-access logic: the core runs the SQL and the schema queries,
//! and this file only presents what comes back.
//!
//! ## What had to be built rather than used
//!
//! glinlandui provides a window, an event loop, a layout engine, a text
//! rasteriser, fifteen basic controls and a headless test driver. It does
//! not provide a data grid, a tree view, or a multi-line text editor —
//! and for a database browser those three *are* the product. So:
//!
//!   - The grid is `box` cells positioned from `grid.visible`, with a
//!     `list` row for selection. It declares only the rows in view,
//!     because the click registry caps at 256 entries per frame.
//!   - The tree is a `box` per table, expanding to its columns.
//!   - The editor is `editor.zig`, a plain byte buffer, drawn as one
//!     `text.label` per line with a caret rendered inline.
//!
//! ## Layout
//!
//!   +------------------+--------------------------------+
//!   | open database    | picker (only when open)        |
//!   | schema tree      +--------------------------------+
//!   | (fixed width)    | SQL editor (grows with content)|
//!   |                  +--------------------------------+
//!   |                  | result grid (scrolls)          |
//!   +------------------+--------------------------------+

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ui = @import("glinlandui");
const box_mod = ui.components.box;
const text_mod = ui.components.text;
const button = ui.components.button;
const input_mod = ui.components.input;
const scroll_mod = ui.components.scroll;
const list_mod = ui.components.list;
const registry = ui.components.click_registry;

const meja = @import("meja");
const database = @import("databases").database;
const query = meja.query;
const value_mod = meja.value;
const schema = meja.schema;
const sql = meja.sql;
const valmod = meja.value;

const app_mod = @import("app.zig");
const App = app_mod.App;
const editor = @import("editor.zig");
const grid = @import("grid.zig");
const picker_mod = @import("picker.zig");
const dialog = @import("dialog.zig");
const theme = @import("theme.zig");

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

/// One table in the sidebar, with its columns loaded lazily.
const TableNode = struct {
    name: []const u8,
    kind: schema.ObjectKind,
    expanded: bool = false,
    columns: ?[]schema.Column = null,
    /// True once a `column count failed, so the tree shows an error
    /// rather than retrying every frame.
    columns_failed: bool = false,
};

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------
//
// `box` children are COMPTIME FUNCTION POINTERS taking ctx by value, so
// every child function must be a top-level declaration, not a closure.

pub fn App_root(ctx: ?*anyopaque, w: u32, h: u32) void {
    root(ctx, w, h);
}

fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.window_w = w;
    self.window_h = h;
    // Every label below borrows from this arena, so it resets once, here,
    // before anything claims space.
    self.beginFrame();

    box_mod.box(.{
        .id = "root",
        .w = .grow,
        .h = .grow,
        .direction = .row,
        .bg = theme.bg_app,
        .gap = 0,
    }, self, rootChildren);
}

fn rootChildren(self: *App) void {
    sidebar(self);
    rightPane(self);
}

/// The left sidebar: the database name, a status line, and the tree.
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
    text_mod.label(.{
        .str = if (self.db_open) self.db_path else "no database",
        .font_size = theme.font_size_small,
        .color = theme.text_dim,
    });

    // Always present, not only when nothing is open. A control that
    // appears and disappears is how a "switch database" feature gets
    // used exactly once.
    button.button(.{
        .id = "sidebar.open",
        .label = if (self.picker.open) "Close picker" else "Open database…",
        .font_size = theme.font_size_small,
        .bg = theme.bg_selected,
        .pad_tb = 4,
        .pad_lr = 10,
        .on_click = onSidebarOpenClick,
        .ctx = self,
    });

    // The SYSTEM dialog, beside the built-in picker rather than instead of
    // it. On a desktop this is the button people reach for — it is the
    // dialog their operating system already taught them — and the picker
    // below is what still works when there is no system dialog, which is
    // every GUI test run and every browser.
    button.button(.{
        .id = "sidebar.browse",
        .label = "Browse…",
        .font_size = theme.font_size_small,
        .bg = theme.bg_header,
        .pad_tb = 4,
        .pad_lr = 10,
        .on_click = onSidebarBrowseClick,
        .ctx = self,
    });

    if (!self.db_open) {
        text_mod.label(.{
            .str = "Ctrl+O to choose one — or Browse…",
            .font_size = theme.font_size_small,
            .color = theme.text_faint,
        });
        return;
    }

    if (self.tables.items.len == 0) {
        text_mod.label(.{ .str = "no tables", .color = theme.text_faint });
        return;
    }

    // Each table is its own box so it can carry an id and a click target.
    // The tree is bounded: a database with 10,000 tables would otherwise
    // declare 10,000 boxes in one frame and blow the click budget.
    const max_nodes = 200;
    const count = @min(self.tables.items.len, max_nodes);
    for (0..count) |i| {
        tableRow(self, i);
    }
    if (self.tables.items.len > max_nodes) {
        // Same rule as every other label: frame arena, not a local.
        const buf = self.claimText(64);
        const more = std.fmt.bufPrint(buf, "... and {d} more", .{
            self.tables.items.len - max_nodes,
        }) catch buf[0..0];
        text_mod.label(.{ .str = more, .color = theme.text_faint });
    }
}

/// Context for one sidebar row. `box.children` receives its ctx by
/// value, so this is how the row index reaches the draw function without
/// a global.
const TreeRowCtx = struct {
    app: *App,
    index: usize,
};

fn tableRow(app: *App, index: usize) void {
    const t = &app.tables.items[index];
    const is_selected = app.selected == index;
    const ctx = TreeRowCtx{ .app = app, .index = index };

    box_mod.box(.{
        .id = treeRowId(index),
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height - 2) },
        .direction = .row,
        .gap = 4,
        .pad = 2,
        .bg = if (is_selected) theme.bg_selected else theme.bg_panel,
        .radius = 3,
    }, ctx, treeRowChildren);

    // `box` never fires on_click, so the click target is registered
    // explicitly once the element exists.
    //
    // The index-carrying `registerZCursor` is used rather than
    // `registerClickCursor` precisely because it takes the row index in
    // the callback. The alternative — stashing the index in a mutable
    // global read by the click thunk — is only correct because declare
    // happens to be single-threaded and immediate, which is a property
    // of the framework rather than of this code.
    registry.registerZCursor(
        ui.zclay.getElementId(treeRowId(index)),
        onTreeRowClick,
        app,
        index,
        0,
        .pointer,
    );
    _ = t;
}

fn treeRowChildren(ctx: TreeRowCtx) void {
    const self = ctx.app;
    if (ctx.index >= self.tables.items.len) return;
    const t = &self.tables.items[ctx.index];

    text_mod.label(.{
        .str = if (t.expanded) "- " else "+ ",
        .font_size = theme.font_size_small,
        .color = theme.text_dim,
    });
    text_mod.label(.{
        .str = t.name,
        .font_size = theme.font_size,
        .color = if (self.selected == ctx.index) theme.text_bright else theme.text,
    });
    if (t.kind == .view) {
        text_mod.label(.{ .str = "view", .color = theme.text_faint });
    }
}

fn onSidebarOpenClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.picker.open) self.closePicker() else self.openPicker();
}

/// The system file dialog. It BLOCKS — a file dialog is modal on every
/// platform, AppKit and COM and the XDG portal alike — so this handler
/// does not return until the user answers, and the window is frozen for
/// the duration. That is the platform's behaviour, not a bug here, and it
/// is why `App.browseForDatabase` always leaves a status line behind:
/// the next frame has to say what happened.
fn onSidebarBrowseClick(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseForDatabase();
}

fn onTreeRowClick(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.browseTable(index);
}

fn treeRowId(index: usize) []const u8 {
    // Small fixed buffer: ids must outlive the declare, and a table name
    // would be unbounded, so an index is used instead.
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "tree.row.{d}", .{index}) catch "tree.row";
    return s;
}

/// The right side: editor on top, result grid below.
fn rightPane(self: *App) void {
    box_mod.box(.{
        .id = "right",
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .gap = 0,
    }, self, rightPaneChildren);
}

fn rightPaneChildren(self: *App) void {
    // The picker is a band across the top, not a modal: it pushes the
    // editor and grid down rather than covering them, so SQL written
    // before is still visible and still editable while a database is
    // being chosen.
    if (self.picker.open) pickerPane(self);
    editorPane(self);
    resultPane(self);
}

// ---------------------------------------------------------------------------
// The database picker
// ---------------------------------------------------------------------------
//
// Built from what glinlandui has: a text field, three buttons, and one
// clickable box per row.
//
// It is NOT the only way to open a database. glinlandui has a
// `file_dialog` — the XDG portal, `NSOpenPanel`, `IFileDialog` — and the
// Browse buttons above reach it. The picker remains because it is the
// path that works everywhere the system dialog does not (a browser, a
// Wayland session with no desktop portal) and because it is what the GUI
// tests can drive at all: a test cannot click a native dialog.

/// Rows drawn in the listing. The click registry caps at 256 entries
/// per frame and the sidebar tree already spends some of that, so the
/// listing states its own bound rather than discovering it.
const max_picker_rows: usize = 8;

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
    // Title + the directory being listed. The directory is the one
    // string that tells the user where the rows below came from.
    box_mod.box(.{
        .id = "picker.head",
        .w = .grow,
        .h = .{ .fixed = 18 },
        .direction = .row,
        .gap = 8,
    }, self, pickerHeadChildren);

    // The path field and its two buttons share a row.
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
    if (self.picker.entries.items.len > count) {
        const buf = self.claimText(64);
        const more = std.fmt.bufPrint(buf, "... and {d} more", .{
            self.picker.entries.items.len - count,
        }) catch buf[0..0];
        text_mod.label(.{ .str = more, .font_size = theme.font_size_small, .color = theme.text_faint });
    }
}

fn pickerHeadChildren(self: *App) void {
    text_mod.label(.{ .str = "Open database", .font_size = theme.font_size_small, .color = theme.text_bright });
    // `db_path` is App-owned storage, so this label is safe the way a
    // local buffer is not.
    text_mod.label(.{ .str = self.picker.dir(), .font_size = theme.font_size_small, .color = theme.text_dim });
}

fn pickerBarChildren(self: *App) void {
    // The editor's Caret maps straight onto glinlandui's EditState —
    // same offset, same anchor — so the field draws its caret and
    // selection without a second representation to keep in step.
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

    // `button` registers its own click target when given `on_click`, so
    // these need no click_registry call of their own.
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
    // The same dialog as the sidebar's Browse, from inside the picker: a
    // user who has opened the listing to find a database should not have to
    // close it again to reach the dialog they actually wanted.
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
    box_mod.box(.{
        .id = pickerRowId(index),
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .gap = 6,
        .pad = 2,
        .bg = if (selected) theme.bg_selected else theme.bg_header,
        .radius = 3,
    }, ctx, pickerRowChildren);

    registry.registerZCursor(
        ui.zclay.getElementId(pickerRowId(index)),
        onPickerRowClick,
        app,
        index,
        0,
        .pointer,
    );
}

fn pickerRowChildren(ctx: PickerRowCtx) void {
    const self = ctx.app;
    if (ctx.index >= self.picker.entries.items.len) return;
    const entry = self.picker.entries.items[ctx.index];
    const selected = self.picker.cursor == ctx.index;

    // A trailing slash is the only marker a directory needs, and it is
    // one the eye reads without a legend.
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

fn pickerRowId(index: usize) []const u8 {
    // Same reasoning as treeRowId: an index keeps the id short and
    // fixed-size, where a file name would be unbounded.
    var buf: [24]u8 = undefined;
    return std.fmt.bufPrint(&buf, "picker.row.{d}", .{index}) catch "picker.row";
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

fn editorPane(self: *App) void {
    const line_count = @max(self.ed.lineCount(), 1);
    const height = @as(f32, @floatFromInt(line_count)) *
        @as(f32, @floatFromInt(theme.row_height)) + 24;

    box_mod.box(.{
        .id = "editor",
        .w = .grow,
        .h = .{ .fixed = @min(height, @as(f32, @floatFromInt(self.window_h / 2))) },
        .direction = .column,
        .bg = theme.bg_editor,
        .pad = 6,
        .gap = 4,
    }, self, editorPaneChildren);
}

fn editorPaneChildren(self: *App) void {
    text_mod.label(.{ .str = "SQL", .color = theme.text_dim });

    // The editor is a plain multi-line buffer, so it is drawn one label
    // per line with a caret block after the character under it. The
    // labels are clipped by the fixed-height box above.
    const line_count = @max(self.ed.lineCount(), 1);
    const caret_line = self.ed.lineNumber(self.ed.caret.offset);
    for (0..line_count) |line| {
        editorLine(self, line, line == caret_line);
    }
}

/// Longest editor line drawn in one piece. The buffer holds 16 KB but
/// the pane is not that wide, so drawing the whole of a pathological
/// line would cost a label nothing can see.
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

    // NOT a local buffer, and this is the whole "typing does nothing"
    // bug. `text.label` is immediate mode: it stores the pointer it is
    // given and the rasteriser reads it later in the frame, after this
    // function has returned. A `var buf` on the stack is dead by then,
    // so every character the user typed was rendered from freed stack
    // and the editor looked permanently blank -- while the buffer, the
    // query engine and the results were all correct.
    //
    // `claimText` is the frame arena the rest of the file already uses
    // for exactly this reason; the editor lines were the one place that
    // was missed. One byte more than the line, for the caret.
    const cap = @min(text.len + 1, max_line_bytes);
    const buf = self.claimText(cap);
    const shown = editor.renderLineWithCaret(text, caret_at, buf);

    text_mod.label(.{
        .str = shown,
        .font_size = theme.font_size,
        .color = theme.text,
    });
}

/// The status line plus the result grid.
fn resultPane(self: *App) void {
    box_mod.box(.{
        .id = "results",
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = theme.bg_app,
        .pad = 6,
        .gap = 4,
    }, self, resultPaneChildren);
}

fn resultPaneChildren(self: *App) void {
    box_mod.box(.{
        .id = "status",
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .gap = 8,
    }, self, statusChildren);

    // The grid itself. It was defined but never called, so the window
    // showed the status line and nothing else -- which no unit test
    // could see, because they all asserted on the result set rather
    // than on what was drawn.
    drawGrid(self, @as(f32, @floatFromInt(self.window_h)) * 0.5, 0);
}

fn statusChildren(self: *App) void {
    text_mod.label(.{ .str = self.status, .color = theme.text_dim });
    if (self.has_result) {
        // Written into the frame arena, not a local: the draw command
        // keeps this pointer until the rasteriser runs.
        const counts = self.claimText(64);
        const counts_text = std.fmt.bufPrint(counts, "{d} rows x {d} cols", .{
            self.result.rowCount(),
            self.result.columnCount(),
        }) catch counts[0..0];
        text_mod.label(.{ .str = counts_text, .color = theme.text_faint });
        if (self.result.truncated) {
            text_mod.label(.{ .str = "truncated", .color = theme.warn });
        }
    }
}

/// The grid itself: a header row plus the virtualised body.
fn drawGrid(self: *App, viewport_h: f32, scroll_y: f32) void {
    if (!self.has_result) {
        text_mod.label(.{ .str = "no results — type SQL and press Ctrl+Enter", .color = theme.text_faint });
        return;
    }
    const total_rows = self.result.rowCount();
    const total_cols = self.result.columnCount();
    if (total_cols == 0) return;

    const vis = grid.visible(.{
        .total_rows = total_rows,
        .total_cols = total_cols,
        .scroll_y = scroll_y,
        .height = viewport_h,
        .width = @floatFromInt(self.window_w),
    });

    const cols = grid.visibleColumns(self.col_widths.items, @floatFromInt(self.window_w), 0);
    if (cols.count == 0) return;

    // Header
    box_mod.box(.{
        .id = "grid.header",
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .gap = 0,
        .bg = theme.bg_header,
    }, self, gridHeaderChildren);

    // Body: only the visible slice is declared, which is what keeps a
    // 1M-row table inside the 256-entry click budget.
    var row: usize = 0;
    while (row < vis.row_count) : (row += 1) {
        const index = vis.first_row + row;
        if (index >= total_rows) break;
        drawGridRow(self, index, cols.first, cols.count);
    }
}

fn gridHeaderChildren(self: *App) void {
    const cols = grid.visibleColumns(self.col_widths.items, @floatFromInt(self.window_w), 0);
    var c: usize = cols.first;
    while (c < cols.first + cols.count) : (c += 1) {
        if (c >= self.col_widths.items.len) break;
        const header = if (c < self.result.columns.len) self.result.columns[c].name else "";
        text_mod.label(.{
            .str = header,
            .font_size = theme.font_size_small,
            .color = theme.text_bright,
        });
    }
}

/// Context for one grid row: which row, and which column window.
/// Passed by value to the `box` child function, which is exactly what
/// that parameter exists for.
const GridRowCtx = struct {
    app: *App,
    row: usize,
    first_col: usize,
    col_count: usize,
};

fn drawGridRow(app: *App, row_index: usize, first_col: usize, col_count: usize) void {
    const ctx = GridRowCtx{
        .app = app,
        .row = row_index,
        .first_col = first_col,
        .col_count = col_count,
    };
    box_mod.box(.{
        .id = gridRowId(row_index),
        .w = .grow,
        .h = .{ .fixed = @floatFromInt(theme.row_height) },
        .direction = .row,
        .gap = 0,
        .bg = if (row_index % 2 == 0) theme.bg_row_even else theme.bg_row_odd,
    }, ctx, gridRowChildren);
}

fn gridRowChildren(ctx: GridRowCtx) void {
    const self = ctx.app;
    if (!self.has_result) return;
    if (ctx.row >= self.result.rowCount()) return;
    const row = self.result.rows[ctx.row];

    var c: usize = 0;
    while (c < ctx.col_count) : (c += 1) {
        const col = ctx.first_col + c;
        if (col >= row.values.len) break;
        const v = row.values[col];
        // NULL is styled differently from the empty string — the whole
        // reason the core recovers storage classes. Without that, the two
        // are the same bytes and could not be told apart here at all.
        const is_null = v.isNull();
        // NOT a local buffer: the draw command keeps this pointer until
        // the rasteriser runs, by which time a local would be dead.
        const buf = self.claimText(512);
        const shown = if (is_null) "NULL" else value_mod.render(buf, v);
        text_mod.label(.{
            .str = shown,
            .font_size = theme.font_size_small,
            .color = if (is_null) theme.text_null_value else theme.text,
        });
    }
}

fn gridRowId(index: usize) []const u8 {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "grid.row.{d}", .{index}) catch "grid.row";
    return s;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = ui.platform.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var app: App = undefined;
    app.init(gpa, threaded.io());
    defer {
        app.clearResult();
        app.freeTables();
        if (app.db_open) app.db.deinit();
    }

    // Open whatever the user named. With no argument the app starts on
    // an in-memory database so the window is never dead on arrival — a
    // database browser that opens to an error is a bad first impression.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1) {
        app.open(argv[1]);
    } else {
        // In-memory rather than an error, so the window is never dead on
        // arrival — but the picker is offered immediately, because
        // "no database" with no way to fix it is the bug this replaced.
        app.open(":memory:");
        app.setStatus("no database open — Ctrl+O to choose one", .{});
    }

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
///
/// The return value is **close intent, not "key consumed"**. The Wayland
/// backend does this:
///
///     if (d.on_key(d.ptr, keymap.toEvdev(key), state == 1)) win.quit = true;
///
/// so returning `true` closes the window. An earlier version forwarded
/// the app's "I handled this key" boolean straight through, which meant
/// the first character typed shut the app down — the editor reported an
/// edit, that is a `true`, and that is a close request.
///
/// So: everything the app consumes returns `false`, and only an explicit
/// Escape asks the window to close.
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
