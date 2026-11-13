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
const editor = ui.text_editor;
const grid = ui.table;
const picker_mod = @import("components/picker.zig");
const dialog = @import("components/dialog.zig");
const theme = @import("theme.zig");
const topbar = @import("views/topbar.zig");
const sidebar_view = @import("views/sidebar.zig");
const workspace = @import("views/workspace.zig");
const status_view = @import("views/status.zig");
const palette_view = @import("views/palette.zig");
const picker_view = @import("views/picker.zig");

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
    // A load requested by the last frame's scroll runs here, before anything is declared.
    self.applyPendingLoad();
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
    topbar.topBar(self);
    if (self.palette_open) palette_view.paletteBand(self);
    if (self.picker.open) picker_view.pickerPane(self);
    mainRow(self);
    status_view.statusBar(self);
}

// ---- top bar --------------------------------------------------------------

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
    sidebar_view.sidebar(self);
    workspace.work(self);
}

// ---- sidebar --------------------------------------------------------------

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
    // Typing arrives as composed text (Caps Lock, Shift and the keyboard layout already applied), not as keycodes.
    host.keys.registerText(App_text_wrapper, &app);

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

/// Adapter between the platform's composed text and the app's focus routing.
fn App_text_wrapper(ctx: ?*anyopaque, text: []const u8) bool {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    return self.onText(text);
}

test {
    _ = editor;
    _ = grid;
    _ = picker_mod;
    _ = theme;
    _ = dialog;
    _ = @import("e2e_test.zig");
}
