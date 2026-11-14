//! Application state for the GUI: what is open, what the editor holds, and what the last query returned.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const database = @import("databases").database;
const query = @import("meja").query;
const schema = @import("meja").schema;
const sql = @import("meja").sql;
const value_mod = @import("meja").value;
const glin = @import("glinlandui");
const input_mod = glin.components.input;
const text_editor = glin.text_editor;

const editor = glin.text_editor;
const grid = glin.table;
const picker_mod = @import("components/picker.zig");
const dialog = @import("components/dialog.zig");
const theme = @import("theme.zig");

/// Measures a run with the font that draws it, so a field's caret sits on the glyph boundary instead of on a guess.
fn measureRun(bytes: []const u8, font_size: u16) f32 {
    return glin.text.measureText(bytes, font_size).w;
}

/// Largest clipboard run this app will move: a SQL editor buffer, not a document.
const clipboard_max: usize = 64 * 1024;

/// Deepest editor line that gets its own click target.
pub const max_editor_lines: usize = 512;

/// One click target per editor line, so a click lands on the line it hit instead of a y computed from a guessed pitch.
pub const LineClick = struct {
    app: *App,
    line: usize,
};

/// Where the clipboard lives: the platform port in the app, a fake in a test, so copy and paste are testable headlessly.
pub const Clipboard = struct {
    read: *const fn (buf: []u8) []const u8,
    write: *const fn (text: []const u8) void,
};

/// The real one: `ui.clipboard`, which is the pasteboard on macOS and a no-op elsewhere.
pub const platform_clipboard: Clipboard = .{
    .read = glin.clipboard.read,
    .write = glin.clipboard.write,
};

/// Which text field owns the keyboard.
pub const Focus = enum { sql_editor, path, tree_search, row_filter, palette };

/// One table in the sidebar, with its columns loaded lazily.
const TableNode = struct {
    name: []const u8,
    kind: schema.ObjectKind,
    expanded: bool = false,
    columns: ?[]schema.Column = null,
    /// True once loading columns failed, so the tree shows an error rather than retrying every frame.
    columns_failed: bool = false,
};

/// One open tab: a table's query, or the user's own.
pub const Tab = struct {
    title: []u8,
    sql: []u8,
    table_index: ?usize,
};

/// What a tree row does when clicked.
pub const TreeAction = union(enum) {
    connection,
    folder_tables,
    folder_views,
    table: usize,
    column: usize,
};

pub const App = struct {
    /// Allocator used for schema and result storage.
    gpa: Allocator,
    io: Io,

    db: database.Db = .{},
    db_open: bool = false,

    /// The open database's path, and the storage behind it.
    db_path_buf: [picker_mod.path_capacity]u8 = undefined,
    db_path_len: usize = 0,
    db_path: []const u8 = "",
    /// Set when the open failed, so the UI can explain why.
    open_error: ?anyerror = null,

    // Schema tree.
    tables: std.ArrayList(TableNode) = .empty,
    /// Index into `tables` of the selected table, if any.
    selected: ?usize = null,

    // Result set.
    result: query.ResultSet = undefined,
    has_result: bool = false,

    /// The status line, and the storage behind it.
    status_buf: [256]u8 = undefined,
    status: []const u8 = "",

    // Column pixel widths, recomputed when a result arrives.
    col_widths: std.ArrayList(u16) = .empty,

    // Editor.
    sql_buf: [16 * 1024]u8 = undefined,

    ed: editor.Editor = undefined,

    // Database selection.
    picker: picker_mod.Picker = undefined,
    focus: Focus = .sql_editor,
    /// Swapped for a fake by the e2e harness, so Cmd+C/V can be asserted without a real pasteboard.
    clipboard: Clipboard = platform_clipboard,
    /// Stable per-line click contexts; the registry keeps the pointer until the release fires.
    line_clicks: [max_editor_lines]LineClick = undefined,

    // Live field contexts, one per field, so a click can find its model.
    tree_search_ctx: input_mod.FieldCtx = undefined,
    filter_ctx: input_mod.FieldCtx = undefined,
    palette_ctx: input_mod.FieldCtx = undefined,

    // Tree search.
    tree_search_buf: [64]u8 = undefined,
    tree_search_ed: text_editor.Editor = undefined,
    tree_search: []const u8 = "",

    // Row filter, pagination and sort.
    filter_buf: [128]u8 = undefined,
    filter_ed: text_editor.Editor = undefined,
    filter: []const u8 = "",
    page: usize = 0,
    /// How many rows the query asks for. Grows as the grid is scrolled, which is what makes the grid lazy instead of paged.
    loaded_rows: usize = 200,
    /// Set when the grid reached the bottom and wants more; consumed at the top of the next frame.
    pending_load: bool = false,
    /// Decides when the grid has scrolled into the bottom zone and needs another chunk. The toolkit owns the rule.
    loader: glin.table.Loader = .{},
    sort_col: ?usize = null,
    sort_dir: i8 = 0,
    /// Display order: result row indices after the filter and the sort.
    row_order: std.ArrayList(usize) = .empty,

    // Tabs: one per opened table.
    tabs: std.ArrayList(Tab) = .empty,
    active_tab: usize = 0,

    // Tree rows, rebuilt each frame from the schema and the search.
    tree_rows: std.ArrayList(glin.components.tree.Row) = .empty,
    tree_actions: std.ArrayList(TreeAction) = .empty,

    // The tab bar's view of `tabs`, rebuilt each frame.
    tab_views: std.ArrayList(glin.components.tabs.Tab) = .empty,

    // Command palette.
    palette_open: bool = false,
    palette_buf: [64]u8 = undefined,
    palette_ed: text_editor.Editor = undefined,
    palette: []const u8 = "",
    palette_idx: usize = 0,

    // Cached layout metrics, refreshed each frame.
    window_w: u32 = 0,
    window_h: u32 = 0,

    /// Tell the models which one the keyboard is going to. The toolkit resets its own frame scratch.
    pub fn beginFrame(self: *App) void {
        // One focus, one caret: an unfocused field draws no caret at all, so exactly one of these is ever true.
        self.ed.focused = self.focus == .sql_editor;
        self.tree_search_ed.focused = self.focus == .tree_search;
        self.filter_ed.focused = self.focus == .row_filter;
        self.palette_ed.focused = self.focus == .palette;
        self.picker.field.focused = self.focus == .path;
    }

    /// Initialise IN PLACE.
    pub fn init(self: *App, gpa: Allocator, io: Io) void {
        self.* = .{ .gpa = gpa, .io = io };
        // Bound to `sql_buf` AFTER the struct is in its final place, so the pointer refers to the App the caller actually holds.
        self.ed = editor.Editor.init(&self.sql_buf);
        self.tree_search_ed = text_editor.Editor.init(&self.tree_search_buf);
        self.filter_ed = text_editor.Editor.init(&self.filter_buf);
        self.palette_ed = text_editor.Editor.init(&self.palette_buf);
        // The live fields need a stable context each, so the click callback can find its model.
        self.tree_search_ctx = .{ .input = &self.tree_search_ed, .id = "sidebar.search", .measure = measureRun, .on_focus = focusTreeSearch, .focus_ctx = self };
        self.filter_ctx = .{ .input = &self.filter_ed, .id = "results.filter", .measure = measureRun, .on_focus = focusFilter, .focus_ctx = self };
        self.palette_ctx = .{ .input = &self.palette_ed, .id = "palette.input", .measure = measureRun, .on_focus = focusPalette, .focus_ctx = self };
        // Same rule for the picker's own field buffer.
        self.picker.init();
        self.setStatus("no database open — Ctrl+O to choose one", .{});
    }

    /// Write the status line.
    pub fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(self.status_buf[0..], fmt, args) catch
            self.status_buf[0..0];
    }

    /// Open a database and load the schema. Safe to call twice.
    pub fn open(self: *App, path: []const u8) void {
        if (self.db_open) {
            self.db.deinit();
            self.db_open = false;
        }
        self.freeTables();
        self.clearResult();

        // `init` takes a NUL-terminated path because it is handed to sqlite3_open; a slice from argv is not sentinel-terminated.
        const zpath = self.gpa.dupeZ(u8, path) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        defer self.gpa.free(zpath);

        self.db.init(self.io, zpath) catch |err| {
            self.open_error = err;
            // Say WHICH path failed, not just that something did.
            self.setStatus("cannot open {s}: {s}", .{ path, @errorName(err) });
            // Leave the previous path alone: it is still what the window is showing, and clearing it would make a failed switch look like a closed database.
            return;
        };
        self.db_open = true;
        self.open_error = null;
        self.setDbPath(path);
        self.loadTables();
        self.setStatus("ready — {s}", .{self.db_path});
    }

    /// Copy the open database's path into storage the App owns.
    fn setDbPath(self: *App, path: []const u8) void {
        const n = @min(path.len, self.db_path_buf.len);
        // Overlap-tolerant, in case a caller passes `self.db_path` back in.
        @memmove(self.db_path_buf[0..n], path[0..n]);
        self.db_path_len = n;
        self.db_path = self.db_path_buf[0..n];
    }

    // --- database selection ------------------------------------------------ The one thing a database browser must let a user do is point it at a.

    /// Show the picker and put the keyboard in the path field.
    pub fn openPicker(self: *App) void {
        self.picker.open = true;
        self.focus = .path;

        // The field starts EMPTY, deliberately.
        self.picker.field.clear();

        // The listing, by contrast, starts where the user already is: the directory holding the open database.
        if (self.picker.dir_len == 0 and self.db_open and self.db_path.len > 0) {
            const parent = picker_mod.parentOf(self.db_path);
            if (picker_mod.Picker.isDirectory(self.io, parent)) self.picker.setDir(parent);
        }
        self.picker.scan(self.gpa, self.io);
        self.setStatus(
            "Enter opens the path — Up/Down choose, Tab goes to SQL, Ctrl+O closes",
            .{},
        );
    }

    /// Ask the SYSTEM file dialog for a database, and open what it returns.
    pub fn browseForDatabase(self: *App) void {
        // Start where the user already is: the directory of the open database, or the picker's if it has one.
        const start: ?[]const u8 = blk: {
            if (self.picker.dir_len > 0) break :blk self.picker.dir();
            if (self.db_open and self.db_path.len > 0 and
                !std.mem.eql(u8, self.db_path, ":memory:"))
            {
                break :blk picker_mod.parentOf(self.db_path);
            }
            break :blk null;
        };

        // `browse` is fallible only because the toolkit's is, and on this target it is always `Unsupported` — which is the case the GUI tests exercise and the.
        const outcome = dialog.browse(self.gpa, start) catch
            dialog.Outcome{ .unavailable = .failed };
        // The path is a COPY the outcome owns, so it is released here.
        defer outcome.free(self.gpa);

        switch (outcome) {
            .opened => |path| {
                if (path.len == 0) {
                    self.setStatus("the file dialog returned an empty path", .{});
                    return;
                }
                // Through `usePath`, like every other route to a database, so "what Browse opens" and "what a clicked row opens" cannot drift apart.
                self.usePath(path);
            },
            .cancelled => {
                // The user closed the window on purpose.
                self.setStatus("browse cancelled — still on {s}", .{if (self.db_open) self.db_path else "nothing"});
            },
            .unavailable => |limit| {
                self.setStatus("{s}", .{limit.explain()});
            },
        }
    }

    pub fn closePicker(self: *App) void {
        self.picker.open = false;
        self.focus = .sql_editor;
        if (self.db_open) self.setStatus("ready — {s}", .{self.db_path});
    }

    /// List `path` as the picker's directory.
    pub fn enterDirectory(self: *App, path: []const u8) void {
        self.picker.setDir(path);
        self.picker.scan(self.gpa, self.io);
        if (self.picker.error_message) |err| {
            self.setStatus("cannot read {s}: {s}", .{ self.picker.dir(), err });
        } else {
            self.setStatus("{d} entries in {s}", .{
                self.picker.entries.items.len,
                self.picker.dir(),
            });
        }
    }

    /// Go up one level, unless already at a root.
    pub fn goUp(self: *App) void {
        const here = self.picker.dir();
        const parent = picker_mod.parentOf(here);
        if (parent.len == 0 or std.mem.eql(u8, parent, here)) {
            self.setStatus("already at the top", .{});
            return;
        }
        self.enterDirectory(parent);
    }

    /// Act on a clicked listing row: a directory is entered, a file opened.
    pub fn activateCandidate(self: *App, index: usize) void {
        const p = &self.picker;
        if (index >= p.entries.items.len) return;
        p.cursor = index;
        const entry = p.entries.items[index];

        // ".." is a navigation row, not a real one: joining it onto the directory would produce a path that does not name anything.
        if (std.mem.eql(u8, entry.name, "..")) {
            self.goUp();
            return;
        }
        const full = p.fullPath(self.gpa, entry) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        defer self.gpa.free(full);
        self.usePath(full);
    }

    /// Open, or — for a directory — enter, whatever is in the path field.
    pub fn openTypedPath(self: *App) void {
        const typed = std.mem.trim(u8, self.picker.field.text(), " \t\r\n");
        if (typed.len == 0) {
            self.setStatus("type a path, or choose one below", .{});
            return;
        }
        self.usePath(typed);
    }

    /// The one place a path becomes the open database, or the listed directory.
    pub fn usePath(self: *App, path: []const u8) void {
        // A directory cannot be opened as a database, and reporting that as an error would be a lie: it is navigation, so it navigates.
        if (picker_mod.Picker.isDirectory(self.io, path)) {
            self.picker.field.setText(path);
            self.enterDirectory(path);
            return;
        }

        self.open(path);
        if (!self.db_open) return; // `open` already said what went wrong.

        self.picker.field.setText(self.db_path);
        // Follow the database into its own directory, so reopening the panel starts where the user now is.
        self.enterDirectory(picker_mod.parentOf(self.db_path));
        self.closePicker();
    }

    pub fn freeTables(self: *App) void {
        for (self.tables.items) |*t| {
            if (t.columns) |cols| {
                schema.freeColumns(self.gpa, cols);
                t.columns = null;
            }
            self.gpa.free(t.name);
        }
        self.tables.deinit(self.gpa);
        self.tables = .empty;
    }

    pub fn clearResult(self: *App) void {
        if (self.has_result) {
            self.result.deinit();
            self.has_result = false;
        }
        self.col_widths.deinit(self.gpa);
        self.col_widths = .empty;
        self.row_order.deinit(self.gpa);
        self.row_order = .empty;
        self.page = 0;
    }

    pub fn loadTables(self: *App) void {
        if (!self.db_open) return;
        const objects = schema.listObjects(self.gpa, &self.db, &.{ .table, .view }) catch {
            self.status = "cannot read schema";
            return;
        };
        defer schema.freeObjects(self.gpa, objects);

        for (objects) |o| {
            self.tables.append(self.gpa, .{
                .name = self.gpa.dupe(u8, o.name) catch return,
                .kind = o.kind,
            }) catch return;
        }
    }

    /// Run whatever is in the editor.
    pub fn runEditor(self: *App) void {
        if (!self.db_open) {
            self.setStatus("no database open — Ctrl+O to choose one", .{});
            return;
        }
        const text = self.ed.text();
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            self.setStatus("nothing to run", .{});
            return;
        }

        const statements = sql.splitStatements(self.gpa, text) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        defer sql.freeStatements(self.gpa, statements);

        // Only the LAST statement's result is shown, which matches what the sqlite3 CLI does: a script's final SELECT is the answer.
        for (statements) |st| {
            self.clearResult();
            self.result = query.run(self.gpa, &self.db, st.text, .{
                .limit = .{ .rows = self.loaded_rows },
            }) catch {
                self.setStatus("query failed", .{});
                continue;
            };
            self.has_result = true;
            if (self.result.error_message) |m| {
                // COPIED, not borrowed.
                self.setStatus("{s}", .{m});
            } else if (self.result.columnCount() == 0) {
                self.setStatus("{d} rows affected", .{self.result.rows_affected});
            } else {
                self.setStatus("ok", .{});
            }
            self.recomputeColumnWidths();
        }
        self.rebuildRowOrder();
    }

    /// Size each column to its widest cell.
    pub fn recomputeColumnWidths(self: *App) void {
        self.col_widths.deinit(self.gpa);
        self.col_widths = .empty;
        if (!self.has_result) return;

        const width = self.result.columnCount();
        for (0..width) |c| {
            // Measure a bounded sample: measuring 200k rows to size a column is exactly the kind of work that makes a browser feel broken, and the width barely.
            var samples: std.ArrayList([]const u8) = .empty;
            defer {
                for (samples.items) |s| self.gpa.free(s);
                samples.deinit(self.gpa);
            }

            var sampled: usize = 0;
            for (self.result.rows) |row| {
                if (sampled >= 100) break;
                if (c >= row.values.len) continue;
                const v = row.values[c];
                if (v.isNull()) continue; // renders as the word "NULL"
                var cell_buf: [256]u8 = undefined;
                const rendered = value_mod.render(&cell_buf, v);
                samples.append(self.gpa, self.gpa.dupe(u8, rendered) catch break) catch break;
                sampled += 1;
            }

            const header = if (c < self.result.columns.len) self.result.columns[c].name else "";
            const w = grid.columnWidth(samples.items, header, theme.font_size, theme.cell_padding);
            self.col_widths.append(self.gpa, w) catch return;
        }
    }

    /// Toggle a table's expansion, loading its columns on first open.
    pub fn toggleTable(self: *App, index: usize) void {
        if (index >= self.tables.items.len) return;
        const t = &self.tables.items[index];
        t.expanded = !t.expanded;
        if (t.expanded and t.columns == null and !t.columns_failed) {
            const cols = schema.listColumns(self.gpa, &self.db, t.name) catch {
                t.columns_failed = true;
                return;
            };
            t.columns = cols;
        }
    }

    /// Load a table's first page into the grid and load it into the editor.
    pub fn browseTable(self: *App, index: usize) void {
        if (index >= self.tables.items.len) return;
        self.selected = index;
        const t = &self.tables.items[index];

        // The editor gets a plain `SELECT *`, which is the query a user would have written, so they can edit it into something else.
        const quoted = sql.quoteIfNeeded(self.gpa, t.name) catch return;
        defer self.gpa.free(quoted);
        const seed = std.fmt.allocPrint(self.gpa, "SELECT * FROM {s}", .{quoted}) catch return;
        defer self.gpa.free(seed);
        self.ed.setText(seed);

        self.runEditor();
    }

    // --- tabs ---------------------------------------------------------------

    /// Open the first table in a tab, so the window is never an empty editor on a database that has one.
    pub fn openFirstTable(self: *App) void {
        if (self.tables.items.len > 0) self.openTableTab(0);
    }

    /// Open a table in a tab, or switch to the tab that already holds it.
    pub fn openTableTab(self: *App, index: usize) void {
        if (index >= self.tables.items.len) return;
        self.saveActiveTab();

        for (self.tabs.items, 0..) |t, i| {
            if (t.table_index) |ti| {
                if (ti == index) {
                    self.active_tab = i;
                    self.selected = index;
                    self.loadActiveTab();
                    return;
                }
            }
        }

        const t = &self.tables.items[index];
        const quoted = sql.quoteIfNeeded(self.gpa, t.name) catch return;
        defer self.gpa.free(quoted);
        const seed = std.fmt.allocPrint(self.gpa, "SELECT * FROM {s}", .{quoted}) catch return;
        const title = self.gpa.dupe(u8, t.name) catch {
            self.gpa.free(seed);
            return;
        };
        self.tabs.append(self.gpa, .{
            .title = title,
            .sql = seed,
            .table_index = index,
        }) catch {
            self.gpa.free(title);
            self.gpa.free(seed);
            return;
        };
        self.active_tab = self.tabs.items.len - 1;
        self.selected = index;
        self.loadActiveTab();
    }

    /// Copy the editor's text into the active tab, so switching away does not lose it.
    fn saveActiveTab(self: *App) void {
        if (self.active_tab >= self.tabs.items.len) return;
        const t = &self.tabs.items[self.active_tab];
        const copy = self.gpa.dupe(u8, self.ed.text()) catch return;
        self.gpa.free(t.sql);
        t.sql = copy;
    }

    /// Load the active tab's SQL into the editor and run it.
    fn loadActiveTab(self: *App) void {
        if (self.active_tab >= self.tabs.items.len) return;
        const t = &self.tabs.items[self.active_tab];
        self.ed.setText(t.sql);
        self.runEditor();
    }

    /// Switch to a tab by index.
    pub fn switchTab(self: *App, i: usize) void {
        if (i >= self.tabs.items.len or i == self.active_tab) return;
        self.saveActiveTab();
        self.active_tab = i;
        self.selected = self.tabs.items[i].table_index;
        self.loadActiveTab();
    }

    /// Close a tab and fall back to its neighbour.
    pub fn closeTab(self: *App, i: usize) void {
        if (i >= self.tabs.items.len) return;
        const t = self.tabs.items[i];
        self.gpa.free(t.title);
        self.gpa.free(t.sql);
        _ = self.tabs.orderedRemove(i);

        if (self.tabs.items.len == 0) {
            self.active_tab = 0;
            self.selected = null;
            self.ed.setText("");
            self.clearResult();
            return;
        }
        if (i < self.active_tab) self.active_tab -= 1;
        if (self.active_tab >= self.tabs.items.len) self.active_tab = self.tabs.items.len - 1;
        self.selected = self.tabs.items[self.active_tab].table_index;
        self.loadActiveTab();
    }

    pub fn freeTabs(self: *App) void {
        for (self.tabs.items) |t| {
            self.gpa.free(t.title);
            self.gpa.free(t.sql);
        }
        self.tabs.deinit(self.gpa);
        self.tabs = .empty;
        self.active_tab = 0;
    }

    // --- tree ---------------------------------------------------------------

    /// Rebuild the tab bar's view of `tabs`. Call once per frame, after `beginFrame`.
    pub fn rebuildTabViews(self: *App) void {
        self.tab_views.clearRetainingCapacity();
        for (self.tabs.items, 0..) |t, i| {
            self.tab_views.append(self.gpa, .{
                .label = t.title,
                .active = i == self.active_tab,
                .closable = true,
                .accent = if (t.table_index != null) theme.accent else null,
            }) catch return;
        }
    }

    /// Rebuild the tree rows from the schema and the search. Call once per frame, after `beginFrame`.
    pub fn rebuildTree(self: *App) void {
        self.tree_rows.clearRetainingCapacity();
        self.tree_actions.clearRetainingCapacity();

        const q = self.tree_search;
        const conn = if (self.db_open) std.fs.path.basename(self.db_path) else "no database";
        self.pushRow(.{
            .label = conn,
            .depth = 0,
            .has_children = true,
            .expanded = true,
            .kind = .group,
            .meta = if (self.db_open) "SQLite" else "",
        }, .connection);

        var tables: usize = 0;
        var views: usize = 0;
        for (self.tables.items) |t| {
            if (!containsIgnoreCase(t.name, q)) continue;
            if (t.kind == .view) views += 1 else tables += 1;
        }

        self.pushRow(.{
            .label = "Tables",
            .depth = 1,
            .has_children = true,
            .expanded = true,
            .kind = .group,
            .meta = glin.frame.formatText("{d}", .{tables}),
        }, .folder_tables);
        self.pushTablesOfKind(q, .table);

        if (views > 0) {
            self.pushRow(.{
                .label = "Views",
                .depth = 1,
                .has_children = true,
                .expanded = true,
                .kind = .group,
                .meta = glin.frame.formatText("{d}", .{views}),
            }, .folder_views);
            self.pushTablesOfKind(q, .view);
        }
    }

    fn pushTablesOfKind(self: *App, q: []const u8, kind: schema.ObjectKind) void {
        for (self.tables.items, 0..) |t, i| {
            if (t.kind != kind) continue;
            if (!containsIgnoreCase(t.name, q)) continue;
            self.pushRow(.{
                .label = t.name,
                .depth = 2,
                .has_children = true,
                .expanded = t.expanded,
                .selected = self.selected == i,
                .kind = .item,
            }, .{ .table = i });
            if (t.expanded) self.pushColumns(i);
        }
    }

    fn pushColumns(self: *App, table_index: usize) void {
        const t = &self.tables.items[table_index];
        const cols = t.columns orelse return;
        for (cols) |c| {
            self.pushRow(.{
                .label = c.name,
                .depth = 3,
                .has_children = false,
                .kind = .leaf,
                .meta = c.declared_type,
            }, .{ .column = table_index });
        }
    }

    fn pushRow(self: *App, row: glin.components.tree.Row, action: TreeAction) void {
        self.tree_rows.append(self.gpa, row) catch return;
        self.tree_actions.append(self.gpa, action) catch {
            _ = self.tree_rows.pop();
        };
    }

    /// Act on a clicked tree row.
    pub fn onTreeSelect(self: *App, row_index: usize) void {
        if (row_index >= self.tree_actions.items.len) return;
        switch (self.tree_actions.items[row_index]) {
            .connection, .folder_tables, .folder_views => {},
            .table => |i| {
                self.toggleTable(i);
                self.openTableTab(i);
            },
            .column => |i| self.openTableTab(i),
        }
    }

    // --- tree search, filter, sort, pagination, palette ---------------------

    /// Rows per page in the grid.
    pub const page_size: usize = 25;

    /// Case-insensitive substring test, ASCII only — enough for table names and cell text.
    pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Set the tree's search text.
    pub fn setTreeSearch(self: *App, text: []const u8) void {
        self.tree_search_ed.setText(text);
        self.tree_search = self.tree_search_ed.text();
    }

    /// Set the grid's row filter and rebuild the display order.
    pub fn setFilter(self: *App, text: []const u8) void {
        self.filter_ed.setText(text);
        self.syncFilter();
    }

    /// Re-read the filter from its editor and rebuild the display order.
    pub fn syncFilter(self: *App) void {
        self.filter = self.filter_ed.text();
        self.page = 0;
        self.rebuildRowOrder();
    }

    /// Set the palette's query text.
    pub fn setPalette(self: *App, text: []const u8) void {
        self.palette_ed.setText(text);
        self.palette = self.palette_ed.text();
        self.palette_idx = 0;
    }

    pub fn openPalette(self: *App) void {
        self.palette_open = true;
        self.focus = .palette;
        self.setPalette("");
    }

    pub fn closePalette(self: *App) void {
        self.palette_open = false;
        self.focus = .sql_editor;
    }

    /// How many tables match the palette's query.
    pub fn paletteMatchCount(self: *App) usize {
        var n: usize = 0;
        for (self.tables.items) |t| {
            if (containsIgnoreCase(t.name, self.palette)) n += 1;
        }
        return n;
    }

    /// The table index of the `i`th palette match.
    pub fn paletteMatchAt(self: *App, i: usize) ?usize {
        var n: usize = 0;
        for (self.tables.items, 0..) |t, idx| {
            if (!containsIgnoreCase(t.name, self.palette)) continue;
            if (n == i) return idx;
            n += 1;
        }
        return null;
    }

    /// Cycle a column's sort: ascending, descending, off.
    pub fn setSort(self: *App, col: usize) void {
        if (self.sort_col) |c| {
            if (c == col) {
                if (self.sort_dir == 1) {
                    self.sort_dir = -1;
                } else if (self.sort_dir == -1) {
                    self.sort_col = null;
                    self.sort_dir = 0;
                } else {
                    self.sort_dir = 1;
                }
            } else {
                self.sort_col = col;
                self.sort_dir = 1;
            }
        } else {
            self.sort_col = col;
            self.sort_dir = 1;
        }
        self.page = 0;
        self.rebuildRowOrder();
    }

    /// Move to a page, clamped.
    pub fn setPage(self: *App, page: usize) void {
        const pages = self.pageCount();
        self.page = @min(page, pages - 1);
    }

    /// The grid is one continuous list, so there is exactly one page.
    pub fn pageCount(self: *App) usize {
        _ = self;
        return 1;
    }

    /// How many rows the grid draws: every loaded row.
    pub fn pageRowCount(self: *App) usize {
        return self.row_order.items.len;
    }

    /// The result row index shown at `display_index`.
    pub fn pageRowAt(self: *App, display_index: usize) ?usize {
        if (display_index >= self.row_order.items.len) return null;
        return self.row_order.items[display_index];
    }

    /// Ask for another chunk of rows. The re-run happens at the top of the next frame, so a frame never changes the result set it is drawing.
    pub fn loadMore(self: *App) void {
        if (!self.has_result or !self.result.truncated) return;
        self.loaded_rows += 200;
        self.pending_load = true;
    }

    /// Re-run the active tab's query at the current row budget.
    pub fn applyPendingLoad(self: *App) void {
        if (!self.pending_load) return;
        self.pending_load = false;
        self.runEditor();
        // The rows are in, so the next entry into the bottom zone may ask again.
        self.loader.arrived();
    }

    /// Recompute the display order from the filter and the sort.
    pub fn rebuildRowOrder(self: *App) void {
        self.row_order.deinit(self.gpa);
        self.row_order = .empty;
        if (!self.has_result) return;

        const total = self.result.rowCount();
        self.row_order.ensureTotalCapacity(self.gpa, total) catch return;
        for (0..total) |i| {
            if (self.filter.len > 0 and !self.rowMatches(i)) continue;
            self.row_order.appendAssumeCapacity(i);
        }

        if (self.sort_col) |col| {
            if (self.sort_dir != 0) {
                std.mem.sort(usize, self.row_order.items, SortCtx{
                    .app = self,
                    .col = col,
                    .dir = self.sort_dir,
                }, SortCtx.lessThan);
            }
        }

        const pages = self.pageCount();
        if (self.page >= pages) self.page = pages - 1;
    }

    /// True when any cell in the row contains the filter text.
    fn rowMatches(self: *App, row_index: usize) bool {
        if (row_index >= self.result.rows.len) return false;
        const row = self.result.rows[row_index];
        var buf: [256]u8 = undefined;
        for (row.values) |v| {
            const shown = if (v.isNull()) "NULL" else value_mod.render(&buf, v);
            if (containsIgnoreCase(shown, self.filter)) return true;
        }
        return false;
    }

    /// Sort context: the app, the column, and the direction.
    const SortCtx = struct {
        app: *App,
        col: usize,
        dir: i8,

        fn lessThan(ctx: SortCtx, a: usize, b: usize) bool {
            const cmp = ctx.app.compareRows(a, b, ctx.col);
            return if (ctx.dir > 0) cmp < 0 else cmp > 0;
        }
    };

    /// Compare two result rows on one column. NULLs sort last in both directions.
    fn compareRows(self: *App, a: usize, b: usize, col: usize) i8 {
        if (a >= self.result.rows.len or b >= self.result.rows.len) return 0;
        const ra = self.result.rows[a];
        const rb = self.result.rows[b];
        if (col >= ra.values.len or col >= rb.values.len) return 0;

        const va = ra.values[col];
        const vb = rb.values[col];
        if (va.isNull() and vb.isNull()) return 0;
        if (va.isNull()) return 1;
        if (vb.isNull()) return -1;

        var ba: [64]u8 = undefined;
        var bb: [64]u8 = undefined;
        const sa = value_mod.render(&ba, va);
        const sb = value_mod.render(&bb, vb);

        // Numbers compare as numbers, so 9 sorts before 10 rather than after it.
        const na = std.fmt.parseFloat(f64, sa) catch null;
        const nb = std.fmt.parseFloat(f64, sb) catch null;
        if (na != null and nb != null) {
            if (na.? < nb.?) return -1;
            if (na.? > nb.?) return 1;
            return 0;
        }
        return switch (std.mem.order(u8, sa, sb)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    /// Route one key event.
    pub fn onKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        // Cmd on macOS, Ctrl everywhere else: the clipboard is one gesture on both.
        if (mods.shortcut()) {
            switch (keycode) {
                editor.KEY_C => return self.copyFocused(),
                editor.KEY_X => return self.cutFocused(),
                editor.KEY_V => return self.pasteFocused(),
                else => {},
            }
        }
        if (mods.shortcut() and keycode == editor.KEY_O) {
            if (self.picker.open) self.closePicker() else self.openPicker();
            return true;
        }
        if (mods.shortcut() and keycode == editor.KEY_K) {
            if (self.palette_open) self.closePalette() else self.openPalette();
            return true;
        }
        if (keycode == editor.KEY_ESCAPE) {
            if (self.palette_open) {
                self.closePalette();
                return true;
            }
            if (self.focus != .sql_editor) {
                self.focus = .sql_editor;
                return true;
            }
        }
        switch (self.focus) {
            .tree_search => return self.onFieldKey(&self.tree_search_ed, keycode, mods, .tree),
            .row_filter => return self.onFieldKey(&self.filter_ed, keycode, mods, .filter),
            .palette => return self.onFieldKey(&self.palette_ed, keycode, mods, .palette),
            .path => return self.onPathKey(mods, keycode),
            .sql_editor => {},
        }
        // The picker is open but the editor has the keyboard: Tab is how the user gets to the path field without reaching for the mouse.
        if (self.picker.open and keycode == editor.KEY_TAB) {
            self.focus = .path;
            return true;
        }
        return self.onEditorKey(mods, keycode);
    }

    /// Composed text from the platform: `A` under Caps Lock, `*`, `(`, `\xc3\xa9`. Routed to whichever field owns the keyboard.
    pub fn onText(self: *App, text: []const u8) bool {
        if (text.len == 0) return false;
        switch (self.focus) {
            .tree_search => return self.onFieldText(&self.tree_search_ed, text, .tree),
            .row_filter => return self.onFieldText(&self.filter_ed, text, .filter),
            .palette => return self.onFieldText(&self.palette_ed, text, .palette),
            .path => return switch (editor.handleText(&self.picker.field, text)) {
                .edited, .run_requested => true,
                .ignored => false,
            },
            .sql_editor => return switch (editor.handleText(&self.ed, text)) {
                .edited, .run_requested => true,
                .ignored => false,
            },
        }
    }

    /// Text for one of the small fields, mirroring `onFieldKey` so the app's copies stay in sync.
    fn onFieldText(self: *App, ed: *text_editor.Editor, text: []const u8, which: Field) bool {
        switch (text_editor.handleText(ed, text)) {
            .edited => {
                switch (which) {
                    .tree => self.tree_search = ed.text(),
                    .filter => self.syncFilter(),
                    .palette => {
                        self.palette = ed.text();
                        self.palette_idx = 0;
                    },
                }
                return true;
            },
            .run_requested, .ignored => return false,
        }
    }

    /// The editor the keyboard is currently typing into.
    fn focusedEditor(self: *App) *text_editor.Editor {
        return switch (self.focus) {
            .tree_search => &self.tree_search_ed,
            .row_filter => &self.filter_ed,
            .palette => &self.palette_ed,
            .path => &self.picker.field,
            .sql_editor => &self.ed,
        };
    }

    /// Copy the focused field's selection to the system clipboard; false when nothing is selected.
    fn copyFocused(self: *App) bool {
        var buf: [clipboard_max]u8 = undefined;
        const copied = text_editor.copySelection(self.focusedEditor(), &buf) orelse return false;
        self.clipboard.write(copied);
        return true;
    }

    /// Cut: copy, then remove the selection; false when nothing is selected.
    fn cutFocused(self: *App) bool {
        var buf: [clipboard_max]u8 = undefined;
        const copied = text_editor.cutSelection(self.focusedEditor(), &buf) orelse return false;
        self.clipboard.write(copied);
        self.syncFocused();
        return true;
    }

    /// Paste the clipboard into the focused field, replacing its selection; false when the clipboard holds no text.
    fn pasteFocused(self: *App) bool {
        var buf: [clipboard_max]u8 = undefined;
        const run = self.clipboard.read(&buf);
        if (run.len == 0) return false;
        if (text_editor.paste(self.focusedEditor(), run) != .edited) return false;
        self.syncFocused();
        return true;
    }

    /// Mirror the focused field back into the app's own copies after an edit that did not go through `onFieldKey`.
    fn syncFocused(self: *App) void {
        switch (self.focus) {
            .tree_search => self.tree_search = self.tree_search_ed.text(),
            .row_filter => self.syncFilter(),
            .palette => {
                self.palette = self.palette_ed.text();
                self.palette_idx = 0;
            },
            .path, .sql_editor => {},
        }
    }

    fn focusTreeSearch(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.focus = .tree_search;
    }

    fn focusFilter(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.focus = .row_filter;
    }

    fn focusPalette(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.focus = .palette;
    }

    /// Which small field a key is going to.
    const Field = enum { tree, filter, palette };

    /// Keys for one of the small text fields. The editor's own handler does the work, so typing, Backspace, Home/End and shift-selection behave exactly as they do in the SQL editor.
    fn onFieldKey(self: *App, ed: *text_editor.Editor, keycode: u32, mods: input_mod.Mods, which: Field) bool {
        switch (text_editor.handleKey(ed, keycode, mods.shift, mods.shortcut())) {
            .edited => {
                ed.idle = 0;
                switch (which) {
                    .tree => self.tree_search = ed.text(),
                    .filter => self.syncFilter(),
                    .palette => {
                        self.palette = ed.text();
                        self.palette_idx = 0;
                    },
                }
                return true;
            },
            .run_requested => {
                self.runEditor();
                return true;
            },
            .ignored => return false,
        }
    }

    fn onEditorKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        switch (editor.handleKey(&self.ed, keycode, mods.shift, mods.shortcut())) {
            .run_requested => {
                self.runEditor();
                return true;
            },
            .edited => return true,
            .ignored => return false,
        }
    }

    /// Keys for the picker's path field.
    fn onPathKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        switch (keycode) {
            editor.KEY_ENTER => {
                self.openTypedPath();
                return true;
            },
            editor.KEY_TAB => {
                self.focus = .sql_editor;
                return true;
            },
            editor.KEY_UP => {
                self.picker.moveCursor(-1);
                return true;
            },
            editor.KEY_DOWN => {
                self.picker.moveCursor(1);
                return true;
            },
            else => {},
        }
        // Everything else — typing, Backspace, Home/End, selection — is exactly what the SQL editor does, so it is literally the same handler and the same.
        return switch (editor.handleKey(&self.picker.field, keycode, mods.shift, mods.shortcut())) {
            .run_requested, .edited => true,
            .ignored => false,
        };
    }
};
